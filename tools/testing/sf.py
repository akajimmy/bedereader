"""Frame pacing as the screen saw it: SurfaceFlinger's present times for the reader's surface during a burst of
page turns. python sf.py <taps|swipes> <count> <gap> [back]
Prints: frames shown, the gaps between them in refreshes (1 = smooth), and every gap over one refresh."""
import subprocess
import sys
import time

ADB = r'C:\Dev\android-sdk\platform-tools\adb.exe'
kind, n, gap = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
back = len(sys.argv) > 4 and sys.argv[4] == 'back'


def sh(cmd):
    return subprocess.run([ADB, 'shell', cmd], stdin=subprocess.DEVNULL, capture_output=True).stdout.decode()


# the app's drawing surface (its number changes each time the app starts)
LAYER = next((l.strip() for l in sh('dumpsys SurfaceFlinger --list').splitlines()
              if l.startswith('SurfaceView[com.nickp.komga_reader') and '(BLAST)' in l), None)
if LAYER is None:
    sys.exit('BeDeReader is not on screen on the tablet')


sh(f"dumpsys SurfaceFlinger --latency-clear '{LAYER}'")
if kind == 'taps':
    x = 100 if back else 1100
    script = ''.join(f'input tap {x} 960; sleep {gap}; ' for _ in range(n))
else:
    x1, x2 = (200, 1000) if back else (1000, 200)
    script = ''.join(f'input swipe {x1} 960 {x2} 960 120; sleep {gap}; ' for _ in range(n))
sh(script)
time.sleep(0.6)
out = sh(f"dumpsys SurfaceFlinger --latency '{LAYER}'").split()
period = int(out[0])
rows = [list(map(int, out[i:i + 3])) for i in range(1, len(out) - 2, 3)]
present = [r[1] for r in rows if 0 < r[1] < 2 ** 62]
present.sort()
gaps = [(b - a) / period for a, b in zip(present, present[1:])]
long = [round(g, 1) for g in gaps if g > 1.5]
moving = [g for g in gaps if g < 6]  # gaps under 6 refreshes: while pages move (longer = at rest between turns)
print(f'{kind} x{n} every {gap}s {"back" if back else "forward"}: {len(present)} frames shown; '
      f'refresh {period / 1e6:.2f} ms')
print(f'  while moving: {len(moving)} gaps, {sum(1 for g in moving if g > 1.5)} over one refresh '
      f'(missed: {sum(round(g) - 1 for g in moving if g > 1.5)} refreshes)')
print('  gaps over one refresh (in refreshes):', long)
# each turn on its own (split at rests of 6+ refreshes): its frames, and where in it the long gaps fall
turns, cur = [], [present[0]] if present else []
for a, b in zip(present, present[1:]):
    if (b - a) / period >= 6:
        turns.append(cur)
        cur = [b]
    else:
        cur.append(b)
if cur:
    turns.append(cur)
for t in turns:
    g = [round((b - a) / period, 1) for a, b in zip(t, t[1:])]
    print(f'  turn: {len(t)} frames over {(t[-1] - t[0]) / 1e6:.0f} ms; gaps: {g}')
