#!/usr/bin/env python3
"""knockwatch: block on the kernel's inotify for a knock queue
directory — event-driven, no polling. Exits at the first knock,
printing the pending filenames. If knocks are already queued
when it starts, it exits immediately: check-then-block, so
re-arming can never miss one. No debounce: speed is a
requirement, and a burst just means the re-armed watcher fires
again (every wake claims all pending files and the consumer's
pull reconciles by high-water, so extra wakes are cheap). The
consumer claims by rename, pulls, and re-arms this.

Canonical source: ai-muse repo, src/knockpipe/knockwatch.py.
Deployed alongside the consumer (e.g. ~/workspace/gmail/).
"""
import ctypes, os, select, sys, time

# Optional argv[2]: the queue directory to watch (default: the
# knockwire demux queue). This is the watch stage's only
# parameterization — the consumer passes its channel's queue.
Q = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 \
    else os.path.expanduser('~/.knockwire/queue')
IN_CLOSE_WRITE = 0x00000008
IN_MOVED_TO = 0x00000080
# Optional argv[1]: max seconds to block before exiting quietly
# with no output (used by the hook host, whose script timeout is
# 600s — the block must end inside it so the script can report).
MAX_BLOCK = float(sys.argv[1]) if len(sys.argv) > 1 else None

def pending():
    try:
        return sorted(f for f in os.listdir(Q) if f.endswith('.knock'))
    except FileNotFoundError:
        return []

p = pending()
if p:
    print('\n'.join(p))
    sys.exit(0)

libc = ctypes.CDLL('libc.so.6', use_errno=True)
fd = libc.inotify_init1(os.O_CLOEXEC)
if fd < 0:
    sys.exit('inotify_init1 failed')
if libc.inotify_add_watch(fd, Q.encode(), IN_CLOSE_WRITE | IN_MOVED_TO) < 0:
    sys.exit('inotify_add_watch failed')

r, _, _ = select.select([fd], [], [], MAX_BLOCK)  # the kernel wait
if not r:
    sys.exit(0)  # block window elapsed with no event: print nothing

os.read(fd, 65536)
# Drain whatever else is already in the kernel buffer, then
# exit at once.
os.set_blocking(fd, False)
try:
    while os.read(fd, 65536):
        pass
except BlockingIOError:
    pass

p = pending()
print('\n'.join(p) if p else '(event, queue empty)')
