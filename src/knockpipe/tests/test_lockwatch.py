#!/usr/bin/env python3
"""Tests for lockwatch.py: exits 0 at once when the lock is
absent; blocks (kernel wait) while it is present and exits 0
when it disappears; exits 1 when the window elapses with the
lock still held.
Run: python3 test_lockwatch.py"""
import os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = os.path.join(HERE, '..', 'lockwatch.py')

fails = 0
def check(name, cond, detail=''):
    global fails
    if not cond:
        fails += 1
    print(('PASS' if cond else 'FAIL'), name, detail)

d = tempfile.mkdtemp(prefix='lockwatch-')
lock = os.path.join(d, 'thinker.lock')

# absent: immediate 0
t0 = time.monotonic()
r = subprocess.run([sys.executable, WATCH, '5', lock],
                   capture_output=True, text=True, timeout=10)
check('absent lock exits 0 at once', r.returncode == 0
      and time.monotonic() - t0 < 2, f'rc={r.returncode}')

# present, removed mid-wait: exits 0 promptly
open(lock, 'w').close()
def remove_later():
    time.sleep(0.6)
    os.remove(lock)
threading.Thread(target=remove_later).start()
t0 = time.monotonic()
r = subprocess.run([sys.executable, WATCH, '5', lock],
                   capture_output=True, text=True, timeout=10)
dt = time.monotonic() - t0
check('removal wakes the wait', r.returncode == 0 and dt < 3,
      f'rc={r.returncode} dt={dt:.2f}')

# present throughout: window elapses, exit 1
open(lock, 'w').close()
t0 = time.monotonic()
r = subprocess.run([sys.executable, WATCH, '1', lock],
                   capture_output=True, text=True, timeout=10)
dt = time.monotonic() - t0
check('held lock times out with 1', r.returncode == 1
      and 0.9 < dt < 3, f'rc={r.returncode} dt={dt:.2f}')

print('lockwatch:', 'FAILED' if fails else 'all passed')
sys.exit(1 if fails else 0)
