#!/usr/bin/env python3
"""Behavior tests for knockwatch.py against a throwaway HOME:
already-pending exits at once, an event during the block wakes
it, and a quiet block window elapses with no output.
Run: python3 test_knockwatch.py"""
import os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = os.path.join(HERE, '..', 'knockwatch.py')

def run_watch(home, max_block, queue=None):
    env = dict(os.environ, HOME=home)
    argv = [sys.executable, WATCH, str(max_block)]
    if queue:
        argv.append(queue)
    return subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)

fails = 0
def check(name, cond, detail=''):
    global fails
    if not cond:
        fails += 1
    print(('PASS' if cond else 'FAIL'), name, detail)

with tempfile.TemporaryDirectory() as home:
    q = os.path.join(home, '.knockwire', 'queue')
    os.makedirs(q)

    # 1. already pending -> immediate exit naming the file
    open(os.path.join(q, 'a.knock'), 'w').close()
    t = time.time()
    out, _ = run_watch(home, 30).communicate()
    check('pending exits immediately', time.time() - t < 5 and 'a.knock' in out,
          f'({time.time() - t:.2f}s)')
    os.remove(os.path.join(q, 'a.knock'))

    # 2. event during block -> wakes and names the file
    proc = run_watch(home, 30)
    def plant():
        time.sleep(0.4)
        open(os.path.join(q, 'b.knock'), 'w').close()
    threading.Thread(target=plant).start()
    t = time.time()
    out, _ = proc.communicate()
    check('event wakes the block', time.time() - t < 5 and 'b.knock' in out,
          f'({time.time() - t:.2f}s)')
    os.remove(os.path.join(q, 'b.knock'))

    # 3. quiet window -> elapses, prints nothing
    t = time.time()
    out, _ = run_watch(home, 1).communicate()
    dt = time.time() - t
    check('quiet window elapses silently', 0.8 < dt < 5 and out == '',
          f'({dt:.2f}s)')

    # 4. argv[2] queue dir override: plant outside HOME's default
    custom = os.path.join(home, 'custom-queue')
    os.makedirs(custom)
    open(os.path.join(custom, 'z.knock'), 'w').close()
    out, _ = run_watch(home, 5, queue=custom).communicate()
    check('argv queue dir honored', 'z.knock' in out)

print('knockwatch:', 'FAILED' if fails else 'all passed')
sys.exit(1 if fails else 0)
