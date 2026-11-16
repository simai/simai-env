#!/usr/bin/env python3
"""Drops one site's scripts from the OPcache, from inside the site's own pool.

    site_opcache.py <pool socket> <site root>

OPcache memory is shared by every pool of a PHP version, so neither
opcache_reset() nor a PHP-FPM reload is used: both would empty the cache of
every site on that version. Instead a small script runs in the site's pool
(one FastCGI request to its socket, as the pool user) and invalidates only
the cached scripts whose path is under the site root.

Prints one JSON line: {"state": "cleared"|"skipped", "scripts": n, "reason": ...}.
"""
import json
import os
import secrets
import shutil
import socket
import struct
import sys

WORK = "/var/lib/simai-env/opcache-clear"
TIMEOUT = 30

SCRIPT = r"""<?php
header('Content-Type: text/plain');
$root = rtrim((string)($_SERVER['SIMAI_SITE_ROOT'] ?? ''), '/') . '/';
$out = ['state' => 'skipped', 'scripts' => 0, 'found' => 0, 'reason' => null];
if ($root === '/') {
    $out['reason'] = 'no_root';
} elseif (!function_exists('opcache_get_status')) {
    $out['reason'] = 'opcache_missing';
} else {
    $status = @opcache_get_status(true);
    if (!is_array($status)) {
        $out['reason'] = 'opcache_off_or_restricted';
    } else {
        $n = 0; $found = 0;
        foreach (array_keys($status['scripts'] ?? []) as $path) {
            if (strncmp($path, $root, strlen($root)) !== 0) {
                continue;
            }
            $found++;
            if (@opcache_invalidate($path, true)) {
                $n++;
            }
        }
        $out = ['state' => 'cleared', 'scripts' => $n, 'found' => $found, 'reason' => null];
    }
}
if (function_exists('opcache_invalidate')) {
    @opcache_invalidate(__FILE__, true);
}
echo "SIMAI-OPCACHE " . json_encode($out) . "\n";
"""


def record(kind, request_id, content):
    out = b""
    while True:
        chunk, content = content[:65535], content[65535:]
        pad = (8 - len(chunk) % 8) % 8
        out += struct.pack("!BBHHBB", 1, kind, request_id, len(chunk), pad, 0) + chunk + b"\0" * pad
        if not content:
            return out


def pair(name, value):
    def size(n):
        return struct.pack("!B", n) if n < 128 else struct.pack("!I", n | 0x80000000)
    name, value = name.encode(), value.encode()
    return size(len(name)) + size(len(value)) + name + value


def fastcgi(sock_path, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.connect(sock_path)
    body = b"".join(pair(k, v) for k, v in params.items())
    s.sendall(record(1, 1, struct.pack("!HB5x", 1, 0))  # BEGIN_REQUEST, responder
              + record(4, 1, body) + record(4, 1, b"")      # PARAMS
              + record(5, 1, b""))                         # STDIN (empty)
    data, out = b"", b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    while len(data) >= 8:
        _, kind, _, length, pad, _ = struct.unpack("!BBHHBB", data[:8])
        content, data = data[8:8 + length], data[8 + length + pad:]
        if kind == 6:  # STDOUT
            out += content
        elif kind == 3:  # END_REQUEST
            break
    return out.decode(errors="replace")


def main():
    sock_path, site_root = sys.argv[1:3]
    answer = {"state": "skipped", "scripts": 0, "found": 0, "reason": None}
    if not os.path.exists(sock_path):
        answer["reason"] = "pool_socket_missing"
        print(json.dumps(answer))
        return 0
    os.makedirs(WORK, mode=0o711, exist_ok=True)
    os.chmod(WORK, 0o711)
    d = os.path.join(WORK, secrets.token_hex(12))
    os.mkdir(d, 0o711)
    try:
        path = os.path.join(d, "clear.php")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w") as f:
            f.write(SCRIPT)
        try:
            text = fastcgi(sock_path, {
                "SCRIPT_FILENAME": path, "SCRIPT_NAME": "/clear.php", "REQUEST_URI": "/clear.php",
                "DOCUMENT_ROOT": d, "REQUEST_METHOD": "GET", "QUERY_STRING": "", "CONTENT_LENGTH": "0",
                "SERVER_PROTOCOL": "HTTP/1.1", "GATEWAY_INTERFACE": "CGI/1.1", "SERVER_SOFTWARE": "simai-env",
                "REMOTE_ADDR": "127.0.0.1", "SERVER_NAME": "localhost", "SERVER_PORT": "80",
                "SIMAI_SITE_ROOT": site_root,
            })
        except OSError as exc:
            answer["reason"] = "pool_unreachable"
            answer["detail"] = exc.__class__.__name__
            print(json.dumps(answer))
            return 0
        for line in text.splitlines():
            if line.startswith("SIMAI-OPCACHE "):
                try:
                    got = json.loads(line[len("SIMAI-OPCACHE "):])
                except ValueError:
                    break
                if isinstance(got, dict):
                    answer.update({k: got.get(k) for k in ("state", "scripts", "found", "reason")})
                    print(json.dumps(answer))
                    return 0
        answer["reason"] = "pool_answer_invalid"
        print(json.dumps(answer))
        return 0
    finally:
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
