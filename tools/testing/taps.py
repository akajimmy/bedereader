"""Tap to turn pages on the tablet: python taps.py <count> <gap seconds> [back]
Forward = a tap near the right edge, back = near the left. One adb shell for all taps (no per-tap adb start-up),
so short gaps are real."""
import subprocess
import sys
import time

ADB = r'C:\Dev\android-sdk\platform-tools\adb.exe'
n = int(sys.argv[1])
gap = float(sys.argv[2])
back = len(sys.argv) > 3 and sys.argv[3] == 'back'
x = 100 if back else 1100
script = ''.join(f'input tap {x} 960; sleep {gap}; ' for _ in range(n))
t = time.time()
subprocess.run([ADB, 'shell', script], stdin=subprocess.DEVNULL, capture_output=True)
print(f'{n} taps {"back" if back else "forward"} every {gap}s in {time.time() - t:.1f}s', flush=True)
