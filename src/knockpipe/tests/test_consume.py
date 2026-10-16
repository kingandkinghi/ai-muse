#!/usr/bin/env python3
"""State-machine tests for knock-consume.sh (the shared channel
consumer), run against stub HOMEs with stub filter/watch stages,
under TWO channel configs — gmail-shaped and slack-shaped — to
prove the consumer is channel-blind: only the KP_* config and
the filter program differ.

Fidelity note (learned live, 2026-10-15): the real hook
runtime's silent/wake EMIT AND EXIT the script. The stub runtime
below therefore records the call and exits too — a stub whose
emit merely returns lets cleanup-after-emit bugs pass, which is
exactly how the first version shipped a recovery loop. If you
change one thing here, keep that exit.

Scenarios: fresh knock -> wake -> next run settles and waits;
crashed predecessor's report is re-issued once; claim without a
parked report re-runs the filter; a dead filter wakes loudly and
clears its claims; a knock landing during the block is claimed
in the same run.
Run: python3 test_consume.py"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'knock-consume.sh')

RUNTIME = '''\
log() { :; }
silent() { printf 'SILENT %s\\n' "$1" >> "$HOME/stub-calls"; exit 0; }
wake() { printf 'WAKE %s\\n' "$1" >> "$HOME/stub-calls"; exit 0; }
'''

# Stub filter honoring the consumer contract: reads claims (for
# gmail-shape, a no-op pull; for slack-shape, one kept item per
# claimed file), parks its report at KP_REPORT, prints it.
# STUB_PULL_MODE: keep1 | keep0 | fail (same knob for both).
FILTER_STUB = '''\
import glob, json, os, sys
mode = os.environ.get('STUB_PULL_MODE', 'keep0')
if mode == 'fail':
    print('stub filter exploded', file=sys.stderr)
    sys.exit(1)
if os.environ.get('STUB_SHAPE') == 'slack':
    n = len(glob.glob(os.path.join(os.environ['KP_CLAIMED_DIR'], '*.knock')))
    kept = [{'event_id': f'Ev{i}', 'text': 'hi'} for i in range(n)] \\
        if mode == 'keep1' else []
    report = {'kept': kept, 'dropped': {}, 'source': 'slack'}
else:
    kept = [{'id': 'm1', 'subject': 'S'}] if mode == 'keep1' else []
    report = {'kept': kept, 'dropped': {}, 'new_history_id': 4242,
              'fallback': False}
rp = os.environ['KP_REPORT']
json.dump(report, open(rp + '.tmp', 'w'))
os.replace(rp + '.tmp', rp)
print(json.dumps(report))
'''

WATCH_STUB = '''\
import os
if os.environ.get('STUB_PLANT') == '1':
    q = os.environ['KP_Q']
    open(os.path.join(q, 'planted.knock'), 'w').close()
'''

# Stub lockwatch for the thinker-lock scenarios. STUB_LOCK_MODE:
# 'held' -> the lock stays (exit 1); 'gone' -> the lock is
# removed during the wait (exit 0); anything else -> exit 0
# without touching it (the stale path never reaches lockwatch).
LOCKWATCH_STUB = '''\
import os, sys
mode = os.environ.get('STUB_LOCK_MODE', '')
if mode == 'gone':
    try:
        os.remove(os.environ['KP_TLOCK'])
    except OSError:
        pass
sys.exit(1 if mode == 'held' else 0)
'''

KEPT1 = {'kept': [{'id': 'm9', 'subject': 'R'}], 'dropped': {},
         'new_history_id': 777, 'fallback': False}
KEPT0 = {'kept': [], 'dropped': {}, 'new_history_id': 777,
         'fallback': False}

fails = 0
def check(name, cond, detail=''):
    global fails
    if not cond:
        fails += 1
    print(('PASS' if cond else 'FAIL'), name, detail)

class Home:
    """A stub deployment. shape='gmail': queue/claimed/report in
    the gmail layout; shape='slack': the slack-relay layout."""
    def __init__(self, shape):
        self.shape = shape
        self.h = tempfile.mkdtemp(prefix=f'consume-{shape}-')
        if shape == 'slack':
            base = f'{self.h}/workspace/slack-relay'
            self.q, self.c = f'{base}/queue.d', f'{base}/claimed.d'
            self.lp = f'{base}/last-filter.json'
        else:
            base = f'{self.h}/workspace/gmail'
            self.q = f'{self.h}/.knockwire/queue'
            self.c = f'{self.h}/.knockwire/claimed'
            self.lp = f'{base}/last-pull.json'
        os.makedirs(self.q)
        os.makedirs(f'{self.c}/archive')
        os.makedirs(base, exist_ok=True)
        self.filter = f'{base}/filter_stub.py'
        self.watch = f'{base}/watch_stub.py'
        self.tlock = f'{base}/thinker.lock'
        self.lockwatch = f'{base}/lockwatch_stub.py'
        self.write_abs(self.filter, FILTER_STUB)
        self.write_abs(self.watch, WATCH_STUB)
        self.write_abs(self.lockwatch, LOCKWATCH_STUB)
        self.write_abs(f'{self.h}/runtime.sh', RUNTIME)
    def make_lock(self, age_s=0):
        self.write_abs(self.tlock, 'wake 0\n')
        if age_s:
            import time
            t = time.time() - age_s
            os.utime(self.tlock, (t, t))
    def write_abs(self, path, text):
        with open(path, 'w') as f:
            f.write(text)
    def knock(self, where='queue', name='k.knock'):
        d = self.q if where == 'queue' else self.c
        open(os.path.join(d, name), 'w').close()
    def park(self, report):
        self.write_abs(self.lp, json.dumps(report))
    def ls(self, d):
        return sorted(f for f in os.listdir(d) if f.endswith('.knock'))
    def exists(self, p):
        return os.path.exists(p)
    def base_env(self, mode, plant='0'):
        return dict(os.environ, HOME=self.h,
                    HATCH_HOOK_RUNTIME=f'{self.h}/runtime.sh',
                    HATCH_HOOK_DRY_RUN='0', STUB_PULL_MODE=mode,
                    STUB_PLANT=plant, STUB_SHAPE=self.shape,
                    KP_Q=self.q, KP_C=self.c, KP_LP=self.lp,
                    KP_WATCH=self.watch,
                    KP_FILTER_CMD=f'python3 {self.filter}',
                    KP_LABEL=self.shape)
    def run(self, mode='keep0', plant='0', tlock=False, lock_mode=''):
        calls = f'{self.h}/stub-calls'
        if os.path.exists(calls):
            os.remove(calls)
        env = self.base_env(mode, plant)
        if tlock:
            env.update(KP_TLOCK=self.tlock,
                       KP_LOCKWATCH=self.lockwatch,
                       STUB_LOCK_MODE=lock_mode)
        r = subprocess.run(['bash', SCRIPT], env=env,
                           capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, f'script failed: {r.stderr}'
        return open(calls).read().strip() if os.path.exists(calls) else ''
    def run_self(self, mode='keep1'):
        # Self-serve: KP_SELF=1 and a BOGUS runtime path — the
        # mode must not touch the hook runtime at all.
        env = self.base_env(mode)
        env.update(KP_SELF='1', KP_TLOCK=self.tlock,
                   KP_LOCKWATCH=self.lockwatch,
                   HATCH_HOOK_RUNTIME='/nonexistent/runtime.sh')
        r = subprocess.run(['bash', SCRIPT], env=env,
                           capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, f'self-serve failed: {r.stderr}'
        return r
    def cleanup(self):
        shutil.rmtree(self.h, ignore_errors=True)

def scenarios(shape):
    tag = shape.upper()
    mark = None
    h = Home(shape)
    mark = h.lp + '.reported'
    # S1+S2: fresh knock, kept -> wake; next run settles, waits.
    h.knock()
    got = h.run(mode='keep1')
    check(f'{tag} S1 wake on kept', got == 'WAKE qualifying messages arrived', got)
    check(f'{tag} S1 knock claimed', h.ls(h.c) == ['k.knock'] and h.ls(h.q) == [])
    check(f'{tag} S1 report parked + marked', h.exists(h.lp) and h.exists(mark))
    got = h.run(mode='keep1')
    check(f'{tag} S2 settle then wait',
          got == 'SILENT block window elapsed, no knocks', got)
    check(f'{tag} S2 claim settled', h.ls(h.c) == [] and not h.exists(h.lp)
          and not h.exists(mark))
    h.cleanup()
    # S3: crashed predecessor, unreported kept report -> re-issue.
    h = Home(shape)
    mark = h.lp + '.reported'
    h.knock(where='claimed')
    h.park(KEPT1)
    got = h.run()
    check(f'{tag} S3 recovered report wakes',
          got == 'WAKE qualifying messages arrived (recovered report)', got)
    check(f'{tag} S3 marker dropped', h.exists(mark))
    h.cleanup()
    # S4: claim, no parked report -> filter re-runs.
    h = Home(shape)
    h.knock(where='claimed')
    got = h.run(mode='keep0')
    check(f'{tag} S4 filter re-runs, silent',
          got == 'SILENT knocks carried no qualifying messages', got)
    h.cleanup()
    # S5: dead filter -> loud wake, claims cleared.
    h = Home(shape)
    h.knock()
    got = h.run(mode='fail')
    check(f'{tag} S5 filter failure wakes', got == 'WAKE filter failed', got)
    check(f'{tag} S5 claims cleared', h.ls(h.c) == [] and h.ls(h.q) == [])
    h.cleanup()
    # S6: knock lands during the block -> claimed in the same run.
    h = Home(shape)
    got = h.run(mode='keep1', plant='1')
    check(f'{tag} S6 mid-block knock wakes',
          got == 'WAKE qualifying messages arrived', got)
    h.cleanup()
    # S7: unreported EMPTY parked report -> settle silently, wait.
    h = Home(shape)
    h.knock(where='claimed')
    h.park(KEPT0)
    got = h.run()
    check(f'{tag} S7 empty recovery settles',
          got == 'SILENT block window elapsed, no knocks', got)
    check(f'{tag} S7 claim cleared', h.ls(h.c) == [] and not h.exists(h.lp))
    h.cleanup()

def lock_scenarios():
    tag = 'LOCK'
    # L1: a wake creates the thinker lock (opt-in channel).
    h = Home('slack')
    h.knock()
    got = h.run(mode='keep1', tlock=True)
    check(f'{tag} L1 wake on kept', got == 'WAKE qualifying messages arrived', got)
    check(f'{tag} L1 lock created at wake', h.exists(h.tlock))
    h.cleanup()
    # L2: fresh lock held -> the consumer abstains: no claim,
    # no wake, the knock stays queued for the awake thinker.
    h = Home('slack')
    h.make_lock()
    h.knock()
    got = h.run(mode='keep1', tlock=True, lock_mode='held')
    check(f'{tag} L2 abstains while locked',
          got == 'SILENT thinker active (lock held); consumer abstaining', got)
    check(f'{tag} L2 knock unclaimed', h.ls(h.q) == ['k.knock'] and h.ls(h.c) == [])
    h.cleanup()
    # L3: a stale lock (dead thinker) is reclaimed; the run
    # proceeds and its wake creates a fresh lock.
    h = Home('slack')
    h.make_lock(age_s=2000)
    h.knock()
    got = h.run(mode='keep1', tlock=True)
    check(f'{tag} L3 stale lock reclaimed, wake',
          got == 'WAKE qualifying messages arrived', got)
    check(f'{tag} L3 fresh lock at wake', h.exists(h.tlock))
    h.cleanup()
    # L4: the lock lifts during the gate wait -> claim proceeds.
    h = Home('slack')
    h.make_lock()
    h.knock()
    got = h.run(mode='keep1', tlock=True, lock_mode='gone')
    check(f'{tag} L4 unlock during gate, wake',
          got == 'WAKE qualifying messages arrived', got)
    h.cleanup()
    # L5: self-serve — the awake thinker claims the next batch
    # itself: report on stdout, epoch bookkeeping completed
    # inline, the lock untouched (the thinker owns its end).
    h = Home('slack')
    h.knock()
    got = h.run(mode='keep1', tlock=True)
    assert got.startswith('WAKE'), got
    h.knock(name='k2.knock')
    r = h.run_self(mode='keep1')
    rep = json.loads(r.stdout)
    check(f'{tag} L5 self-serve reports the batch',
          rep['kept_count'] == 1, r.stdout[:120])
    check(f'{tag} L5 self-serve settled inline',
          h.ls(h.q) == [] and h.ls(h.c) == [] and not h.exists(h.lp))
    check(f'{tag} L5 lock left for the thinker', h.exists(h.tlock))
    r = h.run_self(mode='keep1')
    check(f'{tag} L5 empty self-serve',
          json.loads(r.stdout)['kept_count'] == 0)
    h.cleanup()

scenarios('gmail')
scenarios('slack')
lock_scenarios()
print('knock-consume:', 'FAILED' if fails else 'all passed')
sys.exit(1 if fails else 0)
