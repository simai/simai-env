#!/usr/bin/env python3
"""Server watch: alerts and load history that work while the panel is down.

Run every five minutes as root by `self status-refresh` (cron), right after
lib/site_status.py. It keeps

- /var/lib/simai-env/alerts.json: the alert list. An alert has a stable id
  (same problem, same id), is open while its condition holds, can be
  acknowledged, and is resolved when the condition clears. New and resolved
  alerts are sent to the alert channel, if one is set.
- /var/lib/simai-env/metrics-history.jsonl: one load sample per run, kept 31
  days, answered as 5-minute points for 6 hours or a day and hourly points
  for a week or a month.
- /var/lib/simai-env/metrics-fine.jsonl: one sample a minute (`tick`, its own
  cron line), kept 3 hours, answered as 1-minute points for the last hour.

A sample has the load, memory and disk use, and the averages since the
previous sample of the same kind: CPU busy share, network traffic (physical
interfaces) and disk reads and writes (whole physical disks).

The channel (/etc/simai-env/alerts-channel.json, root only) is a webhook URL
or a Telegram chat; the Telegram bot token is kept in its own root-only file
and is never printed.

Usage: server_watch.py run | tick | alerts [json] | ack ID BY | history PERIOD [json]
       | channel KIND TARGET [TOKEN_FILE] | test
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import host_describe  # noqa: E402
import host_metrics  # noqa: E402

VAR = Path(os.environ.get("SIMAI_WATCH_DIR", "/var/lib/simai-env"))
ALERTS = VAR / "alerts.json"
HISTORY = VAR / "metrics-history.jsonl"
FINE = VAR / "metrics-fine.jsonl"
FINE_KEEP_MINUTES = 180
PERIODS = ("hour", "6h", "day", "week", "month")
RATE_KEYS = ("cpu_percent", "net_rx_bytes_per_s", "net_tx_bytes_per_s", "disk_read_bytes_per_s",
             "disk_write_bytes_per_s")
SYS = Path(os.environ.get("SIMAI_WATCH_SYS", "/sys"))
PROC = Path(os.environ.get("SIMAI_WATCH_PROC", "/proc"))
SECURITY_REPORT = Path(os.environ.get("SIMAI_SECURITY_STATE", "/var/lib/simai-env/security")) / "report.json"
BACKUP_RUNS = Path(os.environ.get("SIMAI_BACKUP_RUNS", "/var/lib/simai-env/backup-runs"))
ETC = Path(os.environ.get("SIMAI_WATCH_ETC", "/etc/simai-env"))
CHANNEL = ETC / "alerts-channel.json"
TG_TOKEN = ETC / "alerts-telegram.token"
PANEL_STATE = Path(os.environ.get("SIMAI_PANEL_STATE", "/etc/simai-env/panel.env"))
KEEP_DAYS = 31
RESOLVED_KEEP_DAYS = 7
DISK_WARN, DISK_CRIT = 90, 95
CERT_DAYS, CERT_CRIT_DAYS = 14, 3
BACKUP_HOURS = 48
DOWN_RUNS = 2  # a site must fail two checks in a row before it alerts
TARGET = re.compile(r"^(https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~/%?&=+:@-]{0,500})?|-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})$")
TOKEN = re.compile(r"^[0-9]{5,12}:[A-Za-z0-9_-]{30,64}$")


def now() -> datetime:
    return datetime.now(timezone.utc)


def stamp(t: datetime | None = None) -> str:
    return (t or now()).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(value: str | None) -> datetime | None:
    if not value:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


def load_json(path: Path, default):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def write_private(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as out:
        out.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def panel_domain() -> str | None:
    try:
        lines = PANEL_STATE.read_text().splitlines()
    except OSError:
        return None
    values = [line.split("=", 1)[1] for line in lines if line.startswith("PANEL_DOMAIN=")]
    return values[-1] or None if values else None


def alert_id(kind: str, target: str) -> str:
    return hashlib.sha256(f"{kind}|{target}".encode()).hexdigest()[:12]


def conditions(metrics: dict, sites: list[dict]) -> list[dict]:
    """What is wrong right now, as alert candidates."""
    found, t = [], now()

    def add(kind, target, severity, message, domain=None):
        found.append({"id": alert_id(kind, target), "kind": kind, "target": target, "domain": domain,
                      "severity": severity, "message": message})

    for d in metrics.get("disk", []):
        if d["total_bytes"]:
            pct = round(d["used_bytes"] * 100 / d["total_bytes"])
            if pct >= DISK_WARN:
                add("disk_full", d["mount"], "critical" if pct >= DISK_CRIT else "warning",
                    f"disk {d['mount']} is {pct}% full")
    panel = panel_domain()
    for s in sites:
        domain = s["domain"]
        cert = s.get("certificate") or {}
        if cert.get("valid") and isinstance(cert.get("days_left"), int) and cert["days_left"] < CERT_DAYS:
            add("cert_expiring", domain, "critical" if cert["days_left"] < CERT_CRIT_DAYS else "warning",
                f"certificate of {domain} expires in {cert['days_left']} days", domain)
        if (cert.get("last_renew") or {}).get("ok") is False:
            add("cert_renew_failed", domain, "warning", f"the last certificate renewal of {domain} failed", domain)
        answers = s.get("answers") or {}
        if answers.get("checked_at"):
            code = answers.get("http")
            if code is None or code >= 500:
                what = "does not answer" if code is None else f"answers HTTP {code}"
                kind = "panel_down" if domain == panel else "site_down"
                add(kind, domain, "critical", f"{'the panel ' if kind == 'panel_down' else ''}{domain} {what}", domain)
        if s.get("backup_schedule"):
            last = parse(s.get("last_backup"))
            if last is None:
                cron = Path("/etc/cron.d") / f"simai-backup-{domain.replace('.', '-')}"
                try:
                    since = datetime.fromtimestamp(cron.stat().st_mtime, timezone.utc)
                except OSError:
                    since = t
            else:
                since = last
            if t - since > timedelta(hours=BACKUP_HOURS):
                add("backup_missing", domain, "warning", f"no backup of {domain} in {BACKUP_HOURS} hours", domain)
        run = load_json(BACKUP_RUNS / f"{domain}.json", {})
        if run.get("ok") is False:
            add("backup_failed", domain, "warning", f"the last backup of {domain} failed", domain)
        if (s.get("last_offsite") or {}).get("ok") is False:
            add("backup_offsite_failed", domain, "warning",
                f"the last backup of {domain} was not uploaded to storage {s['last_offsite'].get('storage')}", domain)
        if (s.get("last_verify") or {}).get("ok") is False:
            add("backup_check_failed", domain, "warning", f"the last check of a backup of {domain} failed", domain)
    # Serious problems found by the security center (security status).
    for c in load_json(SECURITY_REPORT, {}).get("checks") or []:
        if c.get("status") == "risk" and c.get("severity") in ("high", "critical") \
                and c.get("check") not in ("certificate", "backup_offsite"):
            add("security_risk", str(c.get("id")), "critical" if c["severity"] == "critical" else "warning",
                f"security: {c.get('title')}" + (f" ({c['domain']})" if c.get("domain") else "")
                + f": {c.get('detail')}", c.get("domain"))
    return found


def physical_interfaces() -> list[str]:
    try:
        names = sorted(p.name for p in (SYS / "class" / "net").iterdir())
    except OSError:
        return []
    real = [n for n in names if (SYS / "class" / "net" / n / "device").exists()]
    # Containers and some VMs show no device links: every interface but the
    # loopback and the virtual ones of containers and bridges.
    return real or [n for n in names if n != "lo" and not n.startswith(("veth", "docker", "br-", "virbr", "cni"))]


def counters() -> dict:
    """Cumulative CPU, network and disk counters of the host, read from /proc."""
    out: dict = {"t": time.time()}
    try:
        cpu = [int(x) for x in (PROC / "stat").read_text().splitlines()[0].split()[1:]]
        idle = cpu[3] + (cpu[4] if len(cpu) > 4 else 0)
        out["cpu_total"], out["cpu_busy"] = sum(cpu[:8]), sum(cpu[:8]) - idle
    except (OSError, ValueError, IndexError):
        pass
    try:
        wanted, rx, tx = set(physical_interfaces()), 0, 0
        for line in (PROC / "net" / "dev").read_text().splitlines()[2:]:
            name, _, rest = line.partition(":")
            if name.strip() in wanted:
                f = rest.split()
                rx, tx = rx + int(f[0]), tx + int(f[8])
        out["net_rx"], out["net_tx"] = rx, tx
    except (OSError, ValueError, IndexError):
        pass
    try:
        rd = wr = 0
        for line in (PROC / "diskstats").read_text().splitlines():
            f = line.split()
            if len(f) >= 10 and (SYS / "block" / f[2].replace("/", "!") / "device").exists():
                rd, wr = rd + int(f[5]) * 512, wr + int(f[9]) * 512  # sectors are always 512 bytes here
        out["disk_read"], out["disk_write"] = rd, wr
    except (OSError, ValueError):
        pass
    return out


def rates(path: Path, max_gap: int) -> dict:
    """Averages since the counters kept in path; None after a reboot or a long gap."""
    cur, prev = counters(), load_json(path, {})
    write_private(path, json.dumps(cur) + "\n")
    dt = cur["t"] - prev.get("t", 0)
    answer = dict.fromkeys(RATE_KEYS)
    if not 0 < dt <= max_gap:
        return answer

    def delta(key):
        if key in cur and key in prev and cur[key] >= prev[key]:
            return cur[key] - prev[key]
        return None

    busy, total = delta("cpu_busy"), delta("cpu_total")
    if busy is not None and total:
        answer["cpu_percent"] = round(busy * 100 / total, 1)
    for key, name in (("net_rx", "net_rx_bytes_per_s"), ("net_tx", "net_tx_bytes_per_s"),
                      ("disk_read", "disk_read_bytes_per_s"), ("disk_write", "disk_write_bytes_per_s")):
        d = delta(key)
        answer[name] = None if d is None else round(d / dt)
    return answer


def default_interface() -> str | None:
    try:
        for line in (PROC / "net" / "route").read_text().splitlines()[1:]:
            f = line.split()
            if len(f) > 2 and f[1] == "00000000":
                return f[0]
    except OSError:
        pass
    return None


def root_disk() -> Path | None:
    """The /sys/block entry of the disk holding /, through partitions and device-mapper."""
    try:
        dev = os.stat("/").st_dev
        path = (SYS / "dev" / "block" / f"{os.major(dev)}:{os.minor(dev)}").resolve(strict=True)
    except OSError:
        return None
    for _ in range(5):
        if (path / "partition").exists():
            path = path.parent
        slaves = sorted((path / "slaves").glob("*")) if (path / "slaves").is_dir() else []
        if not slaves:
            return path
        path = slaves[0].resolve()
    return path


def host_info() -> dict:
    """Facts for chart titles: the link speed and the kind of the system disk."""
    speed = None
    iface = default_interface()
    if iface:
        try:
            mbit = int((SYS / "class" / "net" / iface / "speed").read_text().strip())
            speed = mbit * 1_000_000 if mbit > 0 else None
        except (OSError, ValueError):
            pass
    kind, name = None, None
    disk = root_disk()
    if disk is not None:
        name = disk.name
        if name.startswith("nvme"):
            kind = "nvme"
        elif name.startswith(("vd", "xvd")):
            kind = "virtual"  # virtio disks do not tell what is under them
        else:
            try:
                kind = "hdd" if (disk / "queue" / "rotational").read_text().strip() == "1" else "ssd"
            except OSError:
                kind = None
    return {"net_interface": iface, "net_link_bits_per_s": speed, "disk_device": name, "disk_kind": kind}


def sample(metrics: dict, measured: dict | None = None) -> dict:
    return {"at": metrics["checked_at"], "load1": metrics["cpu"]["load1"], "cpu_cores": metrics["cpu"]["cores"],
            "memory_used_bytes": metrics["memory"]["used_bytes"], "memory_total_bytes": metrics["memory"]["total_bytes"],
            "swap_used_bytes": metrics["swap"]["used_bytes"],
            "disk": [{"mount": d["mount"], "used_bytes": d["used_bytes"], "total_bytes": d["total_bytes"]}
                     for d in metrics["disk"]],
            **(measured or dict.fromkeys(RATE_KEYS))}


def tick() -> int:
    """One sample a minute for the last-hour chart."""
    point = sample({"checked_at": stamp(), **collect()}, rates(VAR / "metrics-counters-fine.json", 180))
    VAR.mkdir(parents=True, exist_ok=True)
    with open(FINE, "a") as out:
        out.write(json.dumps(point) + "\n")
    lines = FINE.read_text().splitlines()
    if len(lines) > FINE_KEEP_MINUTES + 60:
        write_private(FINE, "".join(l + "\n" for l in lines[-FINE_KEEP_MINUTES:]))
    return 0


def record_sample(point: dict) -> None:
    VAR.mkdir(parents=True, exist_ok=True)
    with open(HISTORY, "a") as out:
        out.write(json.dumps(point) + "\n")
    lines = HISTORY.read_text().splitlines()
    if len(lines) > KEEP_DAYS * 288 + 288:  # prune about once a day
        cutoff = stamp(now() - timedelta(days=KEEP_DAYS))
        write_private(HISTORY, "".join(l + "\n" for l in lines if json.loads(l).get("at", "") >= cutoff))


def mean(values: list, digits: int | None = None):
    known = [v for v in values if isinstance(v, (int, float))]
    if not known:
        return None
    return round(sum(known) / len(known), digits) if digits else round(sum(known) / len(known))


def history(period: str) -> dict:
    span = {"hour": timedelta(hours=1), "6h": timedelta(hours=6), "day": timedelta(days=1),
            "week": timedelta(days=7), "month": timedelta(days=30)}[period]
    cutoff = stamp(now() - span)
    points = []
    try:
        for line in (FINE if period == "hour" else HISTORY).read_text().splitlines():
            try:
                p = json.loads(line)
            except ValueError:
                continue
            if p.get("at", "") >= cutoff:
                points.append(p)
    except OSError:
        pass
    for p in points:  # samples written before 1.50.0 have no averages
        for key in RATE_KEYS:
            p.setdefault(key, None)
    if period in ("week", "month"):  # hourly: averages, the last disk value of the hour
        hours: dict[str, list] = {}
        for p in points:
            hours.setdefault(p["at"][:13], []).append(p)
        points = [{"at": h + ":00:00Z", "load1": round(sum(p["load1"] for p in ps) / len(ps), 2),
                   "cpu_cores": ps[-1]["cpu_cores"],
                   "memory_used_bytes": sum(p["memory_used_bytes"] for p in ps) // len(ps),
                   "memory_total_bytes": ps[-1]["memory_total_bytes"],
                   "swap_used_bytes": sum(p["swap_used_bytes"] for p in ps) // len(ps),
                   "disk": ps[-1]["disk"],
                   **{k: mean([p[k] for p in ps], 1 if k == "cpu_percent" else None) for k in RATE_KEYS}}
                  for h, ps in sorted(hours.items())]
    return {"schema": "simai-metrics-history/1", "period": period,
            "step_seconds": {"hour": 60, "6h": 300, "day": 300}.get(period, 3600), "host": host_info(),
            "points": points}


def channel() -> dict:
    data = load_json(CHANNEL, {})
    return data if data.get("kind") in ("webhook", "telegram") else {"kind": "off"}


def target_hint(ch: dict) -> str | None:
    if ch.get("kind") == "webhook":
        m = re.match(r"^(https?://[^/]+)", ch.get("target", ""))
        return (m.group(1) + "/…") if m else None  # the path may carry a secret
    return ch.get("target") if ch.get("kind") == "telegram" else None


def send(text: str, payload: dict) -> str | None:
    """Deliver one message; returns an error text or None."""
    ch = channel()
    try:
        if ch["kind"] == "webhook":
            req = urllib.request.Request(ch["target"], data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json", "User-Agent": "simai-env"})
        elif ch["kind"] == "telegram":
            token = TG_TOKEN.read_text().strip()
            req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
                                         data=json.dumps({"chat_id": ch["target"], "text": text}).encode(),
                                         headers={"Content-Type": "application/json"})
        else:
            return None
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read(1024)
        return None
    except (OSError, urllib.error.URLError, ValueError) as exc:
        reason = getattr(exc, "reason", None) or getattr(exc, "code", None) or type(exc).__name__
        return f"delivery failed: {str(reason)[:120]}"  # never the URL or token


def notify(state: dict, alert: dict, event: str) -> None:
    host = socket.gethostname()
    mark = {"opened": "⚠", "resolved": "✓", "test": "•"}[event]
    text = f"{mark} {host}: {alert['message']}" + (" (resolved)" if event == "resolved" else "")
    error = send(text, {"schema": "simai-alert-event/1", "host": host, "event": event, "alert": alert})
    if channel()["kind"] != "off":
        state["channel"] = {"last_sent_at": stamp(), "last_error": error}


def load_state() -> dict:
    state = load_json(ALERTS, {})
    state.setdefault("alerts", {})
    state.setdefault("pending", {})
    return state


def save_state(state: dict) -> None:
    write_private(ALERTS, json.dumps(state, ensure_ascii=False, indent=1) + "\n")


def run() -> int:
    metrics = {"checked_at": stamp(), **collect()}
    record_sample(sample(metrics, rates(VAR / "metrics-counters.json", 900)))
    sites = [host_describe.describe_site(d, False, host_describe.site_status()) for d in host_describe.site_domains()]
    state, t = load_state(), stamp()
    current = {c["id"]: c for c in conditions(metrics, sites)}
    pending = state["pending"]
    for cid, c in current.items():
        if c["kind"] in ("site_down", "panel_down"):
            pending[cid] = pending.get(cid, 0) + 1
            if pending[cid] < DOWN_RUNS:
                continue
        a = state["alerts"].get(cid)
        if a and a["state"] in ("open", "acked"):
            a.update(last_seen=t, message=c["message"], severity=c["severity"])
            continue
        state["alerts"][cid] = {**c, "state": "open", "first_seen": t, "last_seen": t,
                                "acked_at": None, "acked_by": None, "resolved_at": None}
        notify(state, state["alerts"][cid], "opened")
    for cid in list(pending):
        if cid not in current:
            del pending[cid]
    cutoff = stamp(now() - timedelta(days=RESOLVED_KEEP_DAYS))
    for cid, a in list(state["alerts"].items()):
        if a["state"] in ("open", "acked") and cid not in current:
            a.update(state="resolved", resolved_at=t)
            notify(state, a, "resolved")
        elif a["state"] == "resolved" and (a.get("resolved_at") or "") < cutoff:
            del state["alerts"][cid]
    state["checked_at"] = t
    save_state(state)
    return 0


def collect() -> dict:
    mem = host_metrics.meminfo()
    load1, load5, load15 = os.getloadavg()
    return {"cpu": {"cores": os.cpu_count(), "load1": round(load1, 2), "load5": round(load5, 2), "load15": round(load15, 2)},
            "memory": {"total_bytes": mem["MemTotal"], "used_bytes": mem["MemTotal"] - mem.get("MemAvailable", mem["MemFree"])},
            "swap": {"total_bytes": mem.get("SwapTotal", 0), "used_bytes": mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)},
            "disk": host_metrics.disks()}


ORDER = {"open": 0, "acked": 1, "resolved": 2}


def alerts_answer() -> dict:
    state = load_state()
    rows = sorted(state["alerts"].values(), key=lambda a: (ORDER.get(a["state"], 3), a["first_seen"]))
    ch = channel()
    info = state.get("channel") or {}
    return {"schema": "simai-alerts/1", "checked_at": state.get("checked_at"), "alerts": rows,
            "channel": {"kind": ch["kind"], "target_hint": target_hint(ch),
                        "last_sent_at": info.get("last_sent_at"), "last_error": info.get("last_error")}}


def ack(aid: str, by: str) -> int:
    state = load_state()
    a = state["alerts"].get(aid)
    if not a:
        print(f"No alert {aid}", file=sys.stderr)
        return 1
    if a["state"] == "open":
        a.update(state="acked", acked_at=stamp(), acked_by=by[:254])
        save_state(state)
    print(f"Alert {aid}: {a['state']}")
    return 0


def set_channel(kind: str, target: str, token_file: str | None) -> int:
    if kind == "off":
        CHANNEL.unlink(missing_ok=True)
        TG_TOKEN.unlink(missing_ok=True)
        print("Alert channel: off")
        return 0
    if not TARGET.match(target or "") or (kind == "webhook") != target.startswith(("http://", "https://")):
        print("--target must be a webhook URL (kind webhook) or a Telegram chat id or @channel (kind telegram)",
              file=sys.stderr)
        return 1
    if kind == "telegram":
        try:
            token = Path(token_file).read_text().strip() if token_file else TG_TOKEN.read_text().strip()
        except OSError:
            print("Telegram needs --token-file with the bot token", file=sys.stderr)
            return 1
        if not TOKEN.match(token):
            print("The file does not hold a Telegram bot token", file=sys.stderr)
            return 1
        write_private(TG_TOKEN, token + "\n", 0o600)
    else:
        TG_TOKEN.unlink(missing_ok=True)
    write_private(CHANNEL, json.dumps({"kind": kind, "target": target}) + "\n", 0o600)
    print(f"Alert channel: {kind} ({target_hint({'kind': kind, 'target': target})})")
    return 0


def test() -> int:
    if channel()["kind"] == "off":
        print("No alert channel; set one with: simai-admin.sh self alerts-channel --kind webhook|telegram --target …",
              file=sys.stderr)
        return 1
    state = load_state()
    notify(state, {"id": "test", "kind": "test", "target": "", "domain": None, "severity": "info",
                   "message": "test message from simai-env"}, "test")
    save_state(state)
    error = state["channel"]["last_error"]
    print(error or "Test message delivered")
    return 1 if error else 0


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["run"]:
        return run()
    if args[:1] == ["tick"]:
        return tick()
    if args[:1] == ["alerts"]:
        data = alerts_answer()
        if args[1:] == ["json"]:
            print(json.dumps(data, ensure_ascii=False))
        else:
            for a in data["alerts"]:
                print(f"{a['id']}  {a['state']:<8} {a['severity']:<8} {a['message']}  (since {a['first_seen']})")
            print(f"Channel: {data['channel']['kind']}" + (f", last error: {data['channel']['last_error']}"
                                                          if data["channel"]["last_error"] else ""))
        return 0
    if args[:1] == ["ack"] and len(args) == 3:
        return ack(args[1], args[2])
    if args[:1] == ["history"] and len(args) >= 2 and args[1] in PERIODS:
        data = history(args[1])
        if args[2:] == ["json"]:
            print(json.dumps(data))
        else:
            for p in data["points"]:
                cpu = "-" if p.get("cpu_percent") is None else f"{p['cpu_percent']}%"
                print(f"{p['at']}  load {p['load1']:<6} cpu {cpu:<6} memory {p['memory_used_bytes'] / (1 << 30):.1f} GiB")
        return 0
    if args[:1] == ["channel"] and len(args) in (3, 4):
        return set_channel(args[1], args[2], args[3] if len(args) == 4 else None)
    if args == ["test"]:
        return test()
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
