#!/usr/bin/env python3
"""lockwatch: block until a lock file disappears — the
consumer's wait-for-unlock while a thinker holds the channel
lock (KP_TLOCK). Kernel inotify on the lock's parent
directory: exits 0 the moment the file is absent (including
already-absent at start — check-then-block, so an unlock can
never be missed), 1 if the block window elapses with the
lock still present. No polling: every wake is a directory
event, and existence is re-checked after each one.

Usage: lockwatch.py <max-seconds> <lock-path>

Canonical source: ai-muse repo, src/knockpipe/lockwatch.py.
Deployed beside knock-consume.sh in the hooks scripts dir.
"""
import ctypes, os, select, sys, time

MAX_BLOCK = float(sys.argv[1])
LOCK = os.path.expanduser(sys.argv[2])

if not os.path.exists(LOCK):
    sys.exit(0)

parent = os.path.dirname(LOCK) or '.'
libc = ctypes.CDLL('libc.so.6', use_errno=True)
fd = libc.inotify_init1(os.O_CLOEXEC)
if fd < 0:
    sys.exit('inotify_init1 failed')
IN_ALL_EVENTS = 0x00000FFF
if libc.inotify_add_watch(fd, parent.encode(), IN_ALL_EVENTS) < 0:
    sys.exit('inotify_add_watch failed')

deadline = time.monotonic() + MAX_BLOCK
while os.path.exists(LOCK):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        sys.exit(1)
    r, _, _ = select.select([fd], [], [], remaining)
    if not r:
        break  # window elapsed
    os.read(fd, 65536)
    os.set_blocking(fd, False)
    try:
        while os.read(fd, 65536):
            pass
    except BlockingIOError:
        pass
    os.set_blocking(fd, True)

sys.exit(0 if not os.path.exists(LOCK) else 1)
