#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode is only needed for the distribution archive. Build a local development
# app or the hardware probe with the installed Swift Command Line Tools.
python3 - "$@" <<'PY'
import argparse
import fnmatch
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

root = pathlib.Path.cwd()
parser = argparse.ArgumentParser()
parser.add_argument('--probe', action='store_true')
parser.add_argument('--identity', default=os.environ.get('WAVEBIRD_SIGNING_IDENTITY'))
parser.add_argument('--profile', default=os.environ.get('WAVEBIRD_PROVISIONING_PROFILE'))
parser.add_argument('--sdk', default=os.environ.get('WAVEBIRD_SDK'))
args = parser.parse_args()
probe = args.probe

# Some CLT releases install an SDK that references SwiftUIMacros without
# shipping its plugin. Prefer an installed SDK without that requirement;
# leave full Xcode's SDK selection alone. --sdk always wins.
def needs_swiftui_plugin(sdk):
    for framework in ('SwiftUI', 'SwiftUICore'):
        module = sdk / 'System/Library/Frameworks' / (framework + '.framework') / 'Modules' / (framework + '.swiftmodule')
        for interface in module.glob('*-apple-macos.swiftinterface'):
            if 'type: "StateMacro"' in interface.read_text():
                return True
    return False

if not args.sdk:
    compiler = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    sdk = pathlib.Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()).resolve()
    plugins = compiler.parent.parent / 'lib/swift/host/plugins'
    if 'CommandLineTools' in str(compiler) and needs_swiftui_plugin(sdk) and not any(plugins.rglob('*SwiftUIMacros*')):
        candidates = {p.resolve() for p in sdk.parent.glob('MacOSX*.sdk') if not needs_swiftui_plugin(p)}
        def sdk_version(p):
            settings = plistlib.loads((p / 'SDKSettings.plist').read_bytes())
            return tuple(int(part) for part in settings['Version'].split('.'))
        if not candidates:
            parser.error('This CLT SDK requires a missing SwiftUI macro plugin. Install full Xcode or supply --sdk with a compatible SDK.')
        args.sdk = str(max(candidates, key=sdk_version))
        print('Using compatible SDK:', args.sdk, flush=True)

if bool(args.identity) != bool(args.profile):
    parser.error('--identity and --profile must be supplied together')
if probe and args.identity:
    parser.error('Sign the app build, then use Tools/GameControllerProbe.swift to inspect its output')
bundle_id = 'dev.alexanderbouman.wavebird.afterglow'
signing_entitlements = None
if args.profile:
    result = subprocess.run(['security', 'cms', '-D', '-i', args.profile], capture_output=True, check=True)
    profile = plistlib.loads(result.stdout)
    granted = profile.get('Entitlements', {})
    app_key = next((key for key in ('com.apple.application-identifier', 'application-identifier') if key in granted), None)
    team = granted.get('com.apple.developer.team-identifier')
    if granted.get('com.apple.developer.hid.virtual.device') is not True or not app_key or not team:
        parser.error('The profile must grant virtual HID and contain its application/team identifiers')
    actual_app_id = team + '.' + bundle_id
    if not fnmatch.fnmatchcase(actual_app_id, granted[app_key]):
        parser.error('The provisioning profile does not cover ' + bundle_id)
    signing_entitlements = {
        'com.apple.developer.hid.virtual.device': True,
        app_key: actual_app_id,
        'com.apple.developer.team-identifier': team,
    }
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
        'CFBundleIdentifier': bundle_id,
        'CFBundleName': 'WaveBird Afterglow',
        'CFBundleDisplayName': 'WaveBird Afterglow',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.9.0-afterglow-dev',
        'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '15.0',
        'NSBluetoothAlwaysUsageDescription': 'WaveBird connects to supported Nintendo and Turtle Beach controllers over Bluetooth.',
        'NSHumanReadableCopyright': 'Copyright 2026 WaveBird contributors. MIT license.',
    }
    (bundle / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))

subprocess.run([
    'swiftc', '-parse-as-library', '-swift-version', '6',
    *(['-sdk', args.sdk] if args.sdk else []),
    '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault',
    '-enable-upcoming-feature', 'MemberImportVisibility',
    '-D', 'DEBUG', '-module-name', 'WaveBird',
    '-target', f'{platform.machine()}-apple-macosx15.0',
    *map(str, sources), '-o', str(executable),
], check=True)

# macOS rejects ad-hoc signatures that claim the restricted virtual-HID
# entitlement. A diagnostic can read physical input, but cannot emulate a gamepad.
sign_command = ['codesign', '--force', '--sign', args.identity or '-']
if signing_entitlements:
    shutil.copyfile(args.profile, bundle / 'Contents' / 'embedded.provisionprofile')
    entitlements = build / 'local-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps(signing_entitlements))
    sign_command += ['--options', 'runtime', '--entitlements', str(entitlements)]
elif not probe:
    (bundle / 'Contents' / 'embedded.provisionprofile').unlink(missing_ok=True)
sign_command.append(str(executable if probe else bundle))
subprocess.run(sign_command, check=True)
if not signing_entitlements:
    print('Input diagnostic build only: virtual gamepads require an Apple-approved signing identity/profile.')
print(executable if probe else bundle)
PY
