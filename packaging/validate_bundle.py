"""Reject symlinks or dynamic dependencies that point outside the staged app."""

import os
import subprocess
import sys
from pathlib import Path


def validate(app):
    app = app.resolve()
    contents = app / "Contents"
    candidates = [contents / "MacOS" / "NewsPaw", contents / "Helpers" / "NewsPawResident"]
    python = contents / "Helpers" / "Python"
    candidates.append(python / "bin" / "python3.13")
    for path in contents.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(contents):
            raise ValueError("Bundle contains a non-relocatable symlink")
        if path.is_file() and (
            path.suffix in {".so", ".dylib"} or path.name in {"ffmpeg", "newspaw-ocr"}
        ):
            candidates.append(path)
    for binary in candidates:
        arch = subprocess.check_output(
            ["/usr/bin/lipo", "-archs", str(binary)], text=True, timeout=10
        )
        if os.uname().machine not in arch.split():
            raise ValueError(f"Incompatible architecture in {binary.name}")
        links = subprocess.check_output(
            ["/usr/bin/otool", "-L", str(binary)], text=True, timeout=10
        ).splitlines()[1:]
        if binary.suffix == ".dylib":
            install_id = subprocess.check_output(
                ["/usr/bin/otool", "-D", str(binary)], text=True, timeout=10
            ).splitlines()[1:]
            if links and links[0].strip().split(" (", 1)[0] in install_id:
                links = links[1:]
        for line in links:
            target = line.strip().split(" (", 1)[0]
            if target.startswith("/") and not target.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError(f"Non-relocatable dependency in {binary.name}")
    print("Relocatable bundle paths verified")


if __name__ == "__main__":
    validate(Path(sys.argv[1]))
