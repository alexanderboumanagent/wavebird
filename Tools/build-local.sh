#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode is only needed for the distribution archive. Build a local development
# app or the hardware probe with the installed Swift Command Line Tools.
python3 - "$@" <<'PY'
import pathlib
import platform
import plistlib
import subprocess
import sys

root = pathlib.Path.cwd()
probe = '--probe' in sys.argv[1:]
build = root / 'build'
build.mkdir(exist_ok=True)
sources = sorted((root / 'WaveBird').rglob('*.swift'))
if probe:
    omitted = {'WaveBirdApp.swift', 'AppDelegate.swift', 'UpdateChecker.swift', 'LaunchAtLoginService.swift'}
    sources = [p for p in sources if p.name not in omitted and 'UI' not in p.relative_to(root / 'WaveBird').parts]
    sources.append(root / 'Tools' / 'AfterglowBridgeProbe.swift')
    executable = build / 'AfterglowBridgeProbe'
else:
    bundle = build / 'WaveBird Afterglow.app'
    executable = bundle / 'Contents' / 'MacOS' / 'WaveBird'
    executable.parent.mkdir(parents=True, exist_ok=True)
    info = {
        'CFBundleExecutable': 'WaveBird',
        'CFBundleIdentifier': 'dev.alexanderbouman.wavebird.afterglow',
        'CFBundleName': 'WaveBird Afterglow',
        'CFBundleDisplayName': 'WaveBird Afterglow',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.9.0-afterglow-dev',
        'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '15.0',
        'NSBluetoothAlwaysUsageDescription': 'WaveBird connects to supported Nintendo controllers over Bluetooth.',
        'NSHumanReadableCopyright': 'Copyright 2026 WaveBird contributors. MIT license.',
    }
    (bundle / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))

subprocess.run([
    'swiftc', '-parse-as-library', '-swift-version', '6',
    '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault',
    '-enable-upcoming-feature', 'MemberImportVisibility',
    '-D', 'DEBUG', '-module-name', 'WaveBird',
    '-target', f'{platform.machine()}-apple-macosx15.0',
    *map(str, sources), '-o', str(executable),
], check=True)

if not probe:
    # Local builds have their own identity and do not replace the installed app.
    # Never reuse the upstream developer's signature or provisioning profile.
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
print(executable if probe else bundle)
PY
