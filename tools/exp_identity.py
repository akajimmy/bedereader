"""The BeDeReader Exp identity, put on the working tree for one build and taken off again.

Every build is BeDeReader Exp unless it's a stable release (user, 2026-10-27: "every build to be building the
experimental app. Only once we publish a new stable version at my specific request will we update the base app").
The Exp app is its own app beside BeDeReader - its own ID, name, data folders and striped "under construction" icon -
so the two never meet on a device. Nothing here is ever committed: tools\\build.ps1 applies it just before building
and restores it straight after; the TestFlight workflow applies it for an exp-build-<n> tag.

  python tools/exp_identity.py apply      the Exp identity on (the files it changes are saved first)
  python tools/exp_identity.py restore    put back what apply saved
  python tools/exp_identity.py status     says whether it's on

The Dart side isn't changed here: the builds pass --dart-define=BEDEREADER_EXP=true (lib/app_identity.dart: the
name shown, the update check off - a BeDeReader release isn't an update to it).

The icons are tools/exp-identity/<the app's path>, made by make_icon.py's striped variant (the tag
archive/experimental-1.7 has it). The text edits are below; each must match exactly as often as listed, or nothing
is changed - an edit that silently stops matching would build the real app's identity under the Exp name.
"""
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = ROOT / 'tools' / 'exp-identity'
SAVED = ROOT / 'build-exp-identity'  # what apply replaced (ignored by git); its manifest says apply is on
MANIFEST = SAVED / 'manifest.json'

# (file, old, new, how many times)
EDITS = [
    ('komga_reader/android/app/build.gradle.kts',
     'applicationId = "com.nickp.komga_reader"', 'applicationId = "com.nickp.komga_reader.exp"', 1),
    ('komga_reader/android/app/src/main/AndroidManifest.xml',
     'android:label="BeDeReader"', 'android:label="BeDeReader Exp"', 1),
    ('komga_reader/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
     '@color/ic_launcher_background', '@drawable/ic_launcher_background', 1),
    ('komga_reader/ios/Runner.xcodeproj/project.pbxproj',
     'PRODUCT_BUNDLE_IDENTIFIER = com.nickp.bedereader;', 'PRODUCT_BUNDLE_IDENTIFIER = com.nickp.bedereader.exp;', 3),
    ('komga_reader/ios/Runner.xcodeproj/project.pbxproj',
     'PRODUCT_BUNDLE_IDENTIFIER = com.nickp.bedereader.RunnerTests;',
     'PRODUCT_BUNDLE_IDENTIFIER = com.nickp.bedereader.exp.RunnerTests;', 3),
    ('komga_reader/ios/Runner/Info.plist', '<string>BeDeReader</string>', '<string>BeDeReader Exp</string>', 2),
    ('komga_reader/windows/runner/Runner.rc',
     'VALUE "FileDescription", "BeDeReader"', 'VALUE "FileDescription", "BeDeReader Exp"', 1),
    # (with CompanyName, the settings folder: %APPDATA%\com.nickp\Komga Reader Exp)
    ('komga_reader/windows/runner/Runner.rc',
     'VALUE "ProductName", "Komga Reader"', 'VALUE "ProductName", "Komga Reader Exp"', 1),
    ('komga_reader/windows/runner/main.cpp', 'L"BeDeReader"', 'L"BeDeReader Exp"', 2),
    ('komga_reader/windows/runner/desktop_channel.cpp', 'L"\\\\KomgaReader"', 'L"\\\\KomgaReaderExp"', 1),
]


def icons():
    return sorted(p.relative_to(FILES).as_posix() for p in FILES.rglob('*') if p.is_file())


def apply():
    if MANIFEST.exists():
        sys.exit(f'already on (an earlier build stopped before restoring?) - run: python tools/exp_identity.py restore')
    changed = {}
    for rel, old, new, times in EDITS:
        text = changed.get(rel)
        if text is None:
            text = (ROOT / rel).read_bytes().decode('utf-8')
        found = text.count(old)
        if found != times:
            sys.exit(f'{rel}: "{old}" found {found} times, expected {times} - nothing changed')
        changed[rel] = text.replace(old, new)
    # saved first, all of it, and checked, before anything is written
    SAVED.mkdir(exist_ok=True)
    touched = sorted(set(changed) | set(icons()))
    added = [rel for rel in touched if not (ROOT / rel).exists()]
    for rel in touched:
        if rel in added:
            continue
        copy = SAVED / 'files' / rel
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, copy)
        if copy.read_bytes() != (ROOT / rel).read_bytes():
            sys.exit(f'{rel}: the saved copy differs - nothing changed')
    MANIFEST.write_text(json.dumps({'replaced': [r for r in touched if r not in added], 'added': added}, indent=1))
    for rel, text in changed.items():
        (ROOT / rel).write_bytes(text.encode('utf-8'))
    for rel in icons():
        (ROOT / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(FILES / rel, ROOT / rel)
    print(f'Exp identity on: {len(changed)} files edited, {len(icons())} icon files (saved in {SAVED.name})')


def restore():
    if not MANIFEST.exists():
        print('Exp identity: not on, nothing to restore')
        return
    m = json.loads(MANIFEST.read_text())
    for rel in m['replaced']:
        shutil.copyfile(SAVED / 'files' / rel, ROOT / rel)
    for rel in m['added']:
        (ROOT / rel).unlink(missing_ok=True)
    bad = [rel for rel in m['replaced'] if (ROOT / rel).read_bytes() != (SAVED / 'files' / rel).read_bytes()]
    bad += [rel for rel in m['added'] if (ROOT / rel).exists()]
    if bad:
        sys.exit(f'restore incomplete, the saved copies are kept in {SAVED}: {bad}')
    shutil.rmtree(SAVED)
    print(f'Exp identity off: {len(m["replaced"])} files put back, {len(m["added"])} removed')


def status():
    print('on' if MANIFEST.exists() else 'off')


if __name__ == '__main__':
    commands = {'apply': apply, 'restore': restore, 'status': status}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]]()
