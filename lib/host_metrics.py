#!/usr/bin/env python3
"""Current host load for the panel: CPU, memory, swap and disks (JSON)."""
import json
import os
import sys
import time

REAL_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "vfat", "overlay"}


def meminfo():
    values = {}
    with open("/proc/meminfo") as stream:
        for line in stream:
            key, _, rest = line.partition(":")
            values[key] = int(rest.split()[0]) * 1024
    return values


def disks():
    rows, seen = [], set()
    with open("/proc/mounts") as stream:
        for line in stream:
            device, mount, fstype = line.split()[:3]
            mount = mount.replace("\\040", " ")
            if fstype not in REAL_FS or device in seen or mount.startswith(("/snap/", "/boot/efi")):
                continue
            seen.add(device)
            try:
                st = os.statvfs(mount)
            except OSError:
                continue
            total = st.f_blocks * st.f_frsize
            rows.append({"mount": mount, "total_bytes": total, "used_bytes": total - st.f_bfree * st.f_frsize})
    return sorted(rows, key=lambda r: r["mount"])


def main():
    mem = meminfo()
    load1, load5, load15 = os.getloadavg()
    data = {
        "schema": "simai-host-metrics/1",
        "cpu": {"cores": os.cpu_count(), "load1": round(load1, 2), "load5": round(load5, 2), "load15": round(load15, 2)},
        "memory": {"total_bytes": mem["MemTotal"], "used_bytes": mem["MemTotal"] - mem.get("MemAvailable", mem["MemFree"])},
        "swap": {"total_bytes": mem.get("SwapTotal", 0), "used_bytes": mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)},
        "disk": disks(),
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if len(sys.argv) > 1 and sys.argv[1] == "json":
        json.dump(data, sys.stdout)
        print()
        return
    gib = 1 << 30
    print(f"CPU     {data['cpu']['cores']} cores, load {load1:.2f} {load5:.2f} {load15:.2f}")
    print(f"Memory  {data['memory']['used_bytes'] / gib:.1f} of {data['memory']['total_bytes'] / gib:.1f} GiB")
    print(f"Swap    {data['swap']['used_bytes'] / gib:.1f} of {data['swap']['total_bytes'] / gib:.1f} GiB")
    for d in data["disk"]:
        print(f"Disk    {d['mount']}: {d['used_bytes'] / gib:.1f} of {d['total_bytes'] / gib:.1f} GiB")


if __name__ == "__main__":
    main()
