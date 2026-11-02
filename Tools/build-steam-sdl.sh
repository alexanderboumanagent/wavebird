#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 <<'PY'
import hashlib
import pathlib
import re
import shutil
import subprocess
import urllib.request

# Match the actual Steam library tested on 2026-11-01; its public API table and
# SDL3_DYNAMIC_API entry are compatible with this exact upstream revision.
revision = 'ab5541ec5'
expected_sha256 = 'b7b3bba118ec3267010daaa008b4f4514f5b0b8c7740e54c84c6305994b94f6a'
build = pathlib.Path('build')
build.mkdir(exist_ok=True)
archive = build / f'SDL-{revision}.tar.gz'
source = build / 'SDL-afterglow-src'
output = build / 'SDL-afterglow'
cmake = shutil.which('cmake')
if not cmake:
    raise SystemExit('CMake is required. Install it from cmake.org or your package manager.')
if not archive.exists():
    urllib.request.urlretrieve(f'https://codeload.github.com/libsdl-org/SDL/tar.gz/{revision}', archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected_sha256:
    raise SystemExit(f'SDL archive checksum mismatch: {archive}')
if not source.exists():
    source.mkdir()
    subprocess.run(['tar', '-xzf', str(archive), '-C', str(source), '--strip-components=1'], check=True)
    with pathlib.Path('Tools/patches/sdl-afterglow-home-light.patch').open('rb') as patch:
        subprocess.run(['patch', '-p1', '--batch'], cwd=source, stdin=patch, check=True)
with pathlib.Path('Tools/patches/sdl-afterglow-home-light.patch').open('rb') as patch:
    result = subprocess.run(['patch', '-p1', '--reverse', '--dry-run', '--batch', '--forward'],
                            cwd=source, stdin=patch, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit('Cached SDL source does not match the compatibility patch. Recreate build/SDL-afterglow-src before rebuilding.')
# SDL3_DYNAMIC_API loads both SDL images into one process. Give this copy's
# private Objective-C classes distinct runtime names to avoid class collisions.
# Public SDL C API/ABI names and Apple framework classes remain unchanged.
private_classes = set()
for path in (source / 'src').rglob('*'):
    if path.suffix in {'.h', '.m', '.mm'}:
        private_classes.update(name for name in re.findall(r'@interface\s+(\w+)\s*:', path.read_text())
                               if name.startswith(('SDL', 'Cocoa_')))
if private_classes:
    names = re.compile(r'\b(' + '|'.join(map(re.escape, sorted(private_classes, key=len, reverse=True))) + r')\b')
    for path in (source / 'src').rglob('*'):
        if path.suffix in {'.h', '.m', '.mm', '.c', '.cpp'}:
            original = path.read_text()
            renamed = names.sub(lambda match: 'Afterglow_' + match.group(), original)
            if original != renamed:
                path.write_text(renamed)
subprocess.run([cmake, '-S', str(source), '-B', str(output),
                '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
                '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64',
                '-DSDL_SHARED=ON', '-DSDL_STATIC=OFF',
                '-DSDL_VENDOR_INFO=WaveBird-Afterglow-ab5541ec5-home-light-v1',
                '-DSDL_TESTS=OFF', '-DSDL_TEST_LIBRARY=OFF'], check=True)
subprocess.run([cmake, '--build', str(output), '--parallel', '4'], check=True)
print((output / 'libSDL3.0.dylib').resolve())
PY
