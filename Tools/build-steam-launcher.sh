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
info = {
    'CFBundleExecutable': executable.name,
    'CFBundleIdentifier': 'dev.alexanderbouman.wavebird.steam-launcher',
    'CFBundleName': 'Steam Afterglow Launcher',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '15.0',
    'LSUIElement': True,
}
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6',
                '-target', f'{platform.machine()}-apple-macosx15.0',
                'Tools/SteamAfterglowLauncher.swift', '-o', str(executable)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
print(bundle.resolve())
PY
