"""Drive the tablet over adb.
    python tab.py list                  - the screen's labelled elements (text / content-desc) and centres
    python tab.py tap "<label part>"    - tap the first element whose text or content-desc contains it
    python tab.py shot <file.png>       - screenshot
    python tab.py key <KEYCODE>         - a key event
    python tab.py xy <x> <y>            - tap a point
"""
import html
import re
import subprocess
import sys
import time

# labels hold any character ("A → Z" in a tooltip): the Windows console's code page can't print them all, and a
# print that failed stopped the script mid-listing (2026-10-07) - written as UTF-8, anything else replaced
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ADB = r'C:\Dev\android-sdk\platform-tools\adb.exe'


def adb(*a, binary=False):
    r = subprocess.run([ADB, *a], capture_output=True, stdin=subprocess.DEVNULL)
    return r.stdout if binary else r.stdout.decode('utf-8', 'replace')


def nodes():
    adb('shell', 'uiautomator', 'dump', '/sdcard/ui.xml')
    x = adb('shell', 'cat', '/sdcard/ui.xml')
    out = []
    for n in re.findall(r'<node [^>]*>', x):
        tm = re.search(r' text="([^"]*)"', n)
        dm = re.search(r'content-desc="([^"]*)"', n)
        bm = re.search(r'bounds="([^"]*)"', n)
        if not bm:
            continue
        t = tm.group(1) if tm else ''
        d = dm.group(1) if dm else ''
        b = list(map(int, re.findall(r'\d+', bm.group(1))))
        if t or d:
            # as shown, not as the XML has it ("Simpsons &amp; Futurama"); line breaks as " | "
            label = html.unescape(t or d).replace('\n', ' | ')
            out.append((label, (b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
    return out


cmd = sys.argv[1]
if cmd == 'list':
    for label, x, y in nodes():
        print(f'{x:5d} {y:5d}  {label[:110]}')
elif cmd == 'tap':
    want = sys.argv[2].lower()
    ns = nodes()
    exact = [n for n in ns if n[0].lower() == want or n[0].lower().split(' | ')[0] == want]
    for label, x, y in exact or ns:
        if exact or want in label.lower():
            adb('shell', 'input', 'tap', str(x), str(y))
            print(f'tapped "{label[:80]}" at {x},{y}')
            time.sleep(1.5)
            break
    else:
        print('NOT FOUND:', sys.argv[2])
        sys.exit(1)
elif cmd == 'shot':
    open(sys.argv[2], 'wb').write(adb('exec-out', 'screencap', '-p', binary=True))
    print('saved', sys.argv[2])
elif cmd == 'key':
    adb('shell', 'input', 'keyevent', sys.argv[2])
elif cmd == 'xy':
    adb('shell', 'input', 'tap', sys.argv[2], sys.argv[3])
