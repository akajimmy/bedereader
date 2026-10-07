"""Swipe pages on the tablet: python swipes.py <count> <gap seconds> [back] [ms per swipe]
Forward = right-to-left. Prints a line per swipe (flushed) with the time, to line up with the trace."""
import subprocess
import sys
import time

ADB = r'C:\Dev\android-sdk\platform-tools\adb.exe'
n = int(sys.argv[1])
gap = float(sys.argv[2])
back = len(sys.argv) > 3 and sys.argv[3] == 'back'
ms = sys.argv[4] if len(sys.argv) > 4 else '180'
# the tablet's screen (portrait): 1200 x 1920 - swipe across the middle
x1, x2, y = (1000, 200, 960) if not back else (200, 1000, 960)
for i in range(n):
    subprocess.run([ADB, 'shell', 'input', 'swipe', str(x1), str(y), str(x2), str(y), ms],
                   stdin=subprocess.DEVNULL, capture_output=True)
    print(time.strftime('%H:%M:%S'), 'swipe', i + 1, 'back' if back else 'forward', flush=True)
    time.sleep(gap)
