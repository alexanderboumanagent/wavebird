#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 <<'PY'
import pathlib
import platform
import plistlib
import subprocess

bundle = pathlib.Path('build/Steam Afterglow Launcher.app')
executable = bundle / 'Contents/MacOS/SteamAfterglowLauncher'
executable.parent.mkdir(parents=True, exist_ok=True)
driver = pathlib.Path('build/SDL-afterglow/libSDL3.0.dylib')
license = pathlib.Path('build/SDL-afterglow-src/LICENSE.txt')
if not driver.exists() or not license.exists():
    raise SystemExit('Build the patched SDL driver first: Tools/build-steam-sdl.sh')
frameworks = bundle / 'Contents/Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
resources = bundle / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
import shutil
shutil.copy2(driver.resolve(), frameworks / 'libSDL3.0.dylib')
shutil.copy2(license, resources / 'SDL-LICENSE.txt')
info = {
    'CFBundleExecutable': executable.name,
    'CFBundleIdentifier': 'dev.alexanderbouman.wavebird.steam-launcher',
    'CFBundleName': 'Steam Afterglow Launcher',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.2.0',
    'CFBundleVersion': '2',
    'LSMinimumSystemVersion': '15.0',
    'LSUIElement': True,
}
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6',
                '-target', f'{platform.machine()}-apple-macosx15.0',
                'Tools/SteamAfterglowLauncher.swift', '-o', str(executable)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(frameworks / 'libSDL3.0.dylib')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
print(bundle.resolve())
PY
