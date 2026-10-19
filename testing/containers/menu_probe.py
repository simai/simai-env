#!/usr/bin/env python3
"""Render and exit both terminal backends under a real controlling PTY."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def probe(backend):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    env = dict(os.environ, TERM="xterm", SIMAI_MENU_BACKEND=backend, SIMAI_AUTO_UPDATE_MODE="off")
    proc = subprocess.Popen(["bash", "./simai-admin.sh", "menu"], stdin=slave,
                            stdout=slave, stderr=slave, env=env, preexec_fn=terminal)
    os.close(slave)
    collected = bytearray()
    deadline = time.monotonic() + 20
    sent = False
    while time.monotonic() < deadline and proc.poll() is None:
        if select.select([master], [], [], 0.1)[0]:
            try:
                collected.extend(os.read(master, 65536))
            except OSError:
                break
        ready = b"Select section" in collected if backend == "text" else b"\x1b[" in collected and b"Sites" in collected
        if not sent and ready:
            time.sleep(0.2)
            os.write(master, b"0\n" if backend == "text" else b"\x1b")
            sent = True
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
        raise AssertionError(f"{backend} did not exit on cancellation; sent={sent}; terminal={bytes(collected[-2500:])!r}")
    os.close(master)
    assert sent and b"SIMAI" in collected, f"{backend} did not render"
    assert proc.returncode == 0, (backend, proc.returncode, collected[-800:])
    print(f"PASS {backend} menu rendered and exited safely on cancellation")


for backend in ("text", "whiptail"):
    probe(backend)
