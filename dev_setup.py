"""Developer toolchain for the Komga client (user OK 2026-09-28): download Flutter SDK, Temurin JDK 17 and the Android
command-line tools into C:\\Dev\\downloads, verify each SHA-256 against the published value, then unpack:
  C:\\Dev\\flutter, C:\\Dev\\jdk17, C:\\Dev\\android-sdk\\cmdline-tools\\latest
No installers, no system settings, no PATH changes. A file whose hash doesn't match is deleted and the run stops.
Progress: C:\\Dev\\setup.log (one line every ~5% per file). Re-running skips files already downloaded and verified."""
import hashlib, os, shutil, sys, time, urllib.request, zipfile
DEV = r"C:\Dev"
DL = os.path.join(DEV, "downloads")
LOG = os.path.join(DEV, "setup.log")
FILES = [
    ("https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.5-stable.zip",
     "flutter_windows_3.47.5-stable.zip", "0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8"),
    ("https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip",
     "OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip", "e53a79c3c3d86865bd7e787903884331068e71321714ffd44f145785affc7cb0"),
    ("https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip",
     "commandlinetools-win-15859902_latest.zip", "90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a"),
]
os.makedirs(DL, exist_ok=True)

def say(m):
    line = f"{time.strftime('%H:%M:%S')} {m}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()

for url, name, want in FILES:
    dst = os.path.join(DL, name)
    if os.path.exists(dst) and sha(dst) == want:
        say(f"{name}: already downloaded and verified"); continue
    say(f"{name}: downloading")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 dev-setup"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dst + ".part", "wb") as out:
        total = int(r.headers.get("Content-Length") or 0)
        got, step, t0 = 0, 0, time.time()
        for b in iter(lambda: r.read(1 << 20), b""):
            out.write(b); got += len(b)
            if total and got * 20 // total > step:
                step = got * 20 // total
                say(f"  {name}: {got / 1e6:.0f}/{total / 1e6:.0f} MB ({got * 100 // total}%), {got / 1e6 / max(time.time() - t0, 1):.1f} MB/s")
    got_sha = sha(dst + ".part")
    if got_sha != want:
        os.remove(dst + ".part")
        say(f"{name}: SHA-256 MISMATCH (got {got_sha}) - deleted, stopping"); sys.exit(1)
    os.replace(dst + ".part", dst)
    say(f"{name}: verified {want[:16]}...")

def unzip(src, target, strip_to=None):
    with zipfile.ZipFile(src) as z:
        z.extractall(target)
    say(f"unpacked {os.path.basename(src)} -> {target}")

if not os.path.exists(os.path.join(DEV, "flutter", "bin", "flutter.bat")):
    unzip(os.path.join(DL, FILES[0][1]), DEV)                     # zip holds flutter\
if not os.path.exists(os.path.join(DEV, "jdk17", "bin", "java.exe")):
    tmp = os.path.join(DEV, "_jdk_tmp")
    unzip(os.path.join(DL, FILES[1][1]), tmp)                     # zip holds jdk-17.0.20.1+1\
    inner = os.path.join(tmp, os.listdir(tmp)[0])
    shutil.move(inner, os.path.join(DEV, "jdk17")); shutil.rmtree(tmp)
latest = os.path.join(DEV, "android-sdk", "cmdline-tools", "latest")
if not os.path.exists(os.path.join(latest, "bin", "sdkmanager.bat")):
    tmp = os.path.join(DEV, "_clt_tmp")
    unzip(os.path.join(DL, FILES[2][1]), tmp)                     # zip holds cmdline-tools\
    os.makedirs(os.path.dirname(latest), exist_ok=True)
    shutil.move(os.path.join(tmp, "cmdline-tools"), latest); shutil.rmtree(tmp)
say("DONE: flutter, jdk17 and android cmdline-tools in place")
