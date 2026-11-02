#!/usr/bin/env python3
"""Temporary, reversible Steam name aliases for one inspected Stick Fight build."""

import argparse
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ORIGINAL_SHA256 = "d0e974f0641d45429fd9ecaf5987f48fc98ae0ed0826dc42410ba8607fff37e2"
ASSEMBLY = Path.home() / (
    "Library/Application Support/Steam/steamapps/common/StickFightTheGame/"
    "StickFight.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll"
)
BACKUP = Path.home() / (
    "Library/Application Support/WaveBird Afterglow/Backups/StickFight/"
    + ORIGINAL_SHA256 + "/Assembly-CSharp.dll"
)
# Inspected 2026-11-01: referenced only by Xbox360MacProfile..ctor. Its existing
# mappings match Steam's virtual Xbox devices, so no IL or mappings are changed.
ALIASES = (
    (0x1261EB, "Microsoft Wireless 360 Controller", 0, "Microsoft GamePad-1"),
    (0x12622F, "Mad Catz, Inc. Mad Catz FPS Pro GamePad", 0, "Microsoft GamePad-2"),
    (0x12627F, "Mad Catz, Inc. MadCatz Call of Duty GamePad", 0, "Microsoft GamePad-3"),
    (0x1262D7, "©Microsoft Corporation Controller", 1, "Microsoft GamePad-4"),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def user_string(value, flag):
    # ECMA-335 II.24.2.4: byte length, UTF-16, terminal special-character flag.
    # Hyphens require flag 1 even though they are ASCII.
    utf16 = value.encode("utf-16-le")
    if len(utf16) + 1 >= 128:
        raise ValueError("This tool supports only the inspected short string records.")
    return bytes([len(utf16) + 1]) + utf16 + bytes([flag])


def patched_bytes(original):
    if digest(original) != ORIGINAL_SHA256:
        raise ValueError("Unrecognized game build; refusing to patch it.")
    result = bytearray(original)
    for offset, old, old_flag, new in ALIASES:
        expected, replacement = user_string(old, old_flag), user_string(new, 1)
        if result[offset:offset + len(expected)] != expected or len(replacement) > len(expected):
            raise ValueError("Unexpected string record; refusing to patch it.")
        # Preserve file size, every later heap offset and all method bodies.
        result[offset:offset + len(expected)] = replacement.ljust(len(expected), b"\0")
    return bytes(result)


def atomic_write(path, data, mode):
    fd, name = tempfile.mkstemp(prefix=".afterglow-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "apply", "restore"))
    parser.add_argument("--assembly", type=Path, default=ASSEMBLY)
    parser.add_argument("--backup", type=Path, default=BACKUP)
    args = parser.parse_args()
    assembly = args.assembly.resolve(strict=True)
    backup = args.backup.expanduser().absolute()
    if assembly == backup.resolve():
        raise ValueError("Backup must be separate from the game assembly.")
    current = assembly.read_bytes()
    original = current if digest(current) == ORIGINAL_SHA256 else backup.read_bytes()
    patched = patched_bytes(original)
    if current not in (original, patched):
        raise ValueError("Game assembly changed; refusing to overwrite it.")
    print("Original build" if current == original else "Steam aliases installed")
    print("SHA-256:", digest(current))
    if args.action == "check":
        return
    if subprocess.run(["pgrep", "-x", "StickFight"], capture_output=True).returncode == 0:
        raise ValueError("Quit Stick Fight before changing its assembly.")
    if args.action == "apply":
        backup.parent.mkdir(parents=True, exist_ok=True)
        if backup.exists():
            if backup.read_bytes() != original:
                raise ValueError("Existing backup differs; refusing to replace it.")
        else:
            with backup.open("xb") as handle:
                handle.write(original)
                handle.flush()
                os.fsync(handle.fileno())
        desired = patched
    else:
        if backup.read_bytes() != original:
            raise ValueError("Backup failed verification; refusing to restore it.")
        desired = original
    atomic_write(assembly, desired, stat.S_IMODE(assembly.stat().st_mode))
    if assembly.read_bytes() != desired:
        raise ValueError("Write verification failed.")
    print(args.action.capitalize(), "complete; SHA-256:", digest(desired))
    print("Backup:", backup)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print("Error:", error, file=sys.stderr)
        sys.exit(1)
