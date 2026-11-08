"""Reject symlinks or dynamic dependencies that point outside the staged app."""

import os
import re
import subprocess
import sys
from pathlib import Path

_SYSTEM_ROOTS = (Path("/usr/lib"), Path("/System/Library"))
_LINKS = {
    "LC_LOAD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_DYLINKER",
}
_COMMAND = re.compile(
    r"^\s*cmd (LC_[A-Z_]+)\n\s*cmdsize \d+\n\s*(?:name|path) (.+) \(offset \d+\)$",
    re.MULTILINE,
)


def _system(path):
    normalized = Path(os.path.normpath(path))
    return any(normalized.is_relative_to(root) and path.resolve().is_relative_to(root) for root in _SYSTEM_ROOTS)


def _bundle_path(value, binary, executable, contents):
    anchor, _, suffix = value.partition("/")
    roots = {"@loader_path": binary.parent, "@executable_path": executable.parent}
    if anchor in roots:
        path = (roots[anchor] / suffix).resolve()
        if path.is_relative_to(contents):
            return path
    raise ValueError(f"Non-relocatable dependency in {binary.name}: {value}")


def _validate_link(target, runpaths, binary, executable, contents, binaries):
    path = Path(target)
    if path.is_absolute() and _system(path):
        return
    if (
        target.startswith(("@loader_path/", "@executable_path/"))
        and _bundle_path(target, binary, executable, contents) in binaries
    ):
        return
    if target.startswith("@rpath/"):
        suffix = target.removeprefix("@rpath/")
        # Require a resolution in this image's declared search paths, independent of
        # whatever paths an upstream loader or the build environment might add.
        for runpath in runpaths:
            root = Path(runpath)
            if root.is_absolute() and _system(root):
                candidate = (root / suffix).resolve()
                if _system(candidate) and candidate.is_file():
                    return
                continue
            root = _bundle_path(runpath, binary, executable, contents)
            candidate = (root / suffix).resolve()
            if not candidate.is_relative_to(contents):
                raise ValueError(f"Non-relocatable dependency in {binary.name}: {target}")
            if candidate in binaries:
                return
    raise ValueError(f"Unresolved or non-relocatable dependency in {binary.name}: {target}")


def validate(app):
    contents = app.resolve() / "Contents"
    main = contents / "MacOS" / "NewsPaw"
    python = contents / "Helpers" / "Python"
    python_executable = python / "bin" / "python3.13"
    executables = {main, contents / "Helpers" / "NewsPawResident", python_executable}
    libraries = set()
    for path in contents.rglob("*"):
        if path.is_symlink() and (
            Path(os.readlink(path)).is_absolute() or not path.resolve().is_relative_to(contents)
        ):
            raise ValueError("Bundle contains a non-relocatable symlink")
        if path.is_file():
            if path.name in {"ffmpeg", "ffprobe", "newspaw-ocr"}:
                executables.add(path.resolve())
            elif path.suffix in {".so", ".dylib"}:
                libraries.add(path.resolve())
    binaries = executables | libraries
    architecture = os.uname().machine
    for binary in sorted(binaries):
        arch = subprocess.check_output(
            ["/usr/bin/lipo", "-archs", str(binary)], text=True, timeout=10
        )
        if architecture not in arch.split():
            raise ValueError(f"Incompatible architecture in {binary.name}")
        listing = subprocess.check_output(
            ["/usr/bin/otool", "-arch", architecture, "-l", str(binary)], text=True, timeout=10
        )
        commands = _COMMAND.findall(listing)
        runpaths = [path for command, path in commands if command == "LC_RPATH"]
        executable = binary
        if binary not in executables:
            executable = python_executable if binary.is_relative_to(python) else main
        for command, target in commands:
            if command in _LINKS:
                _validate_link(target, runpaths, binary, executable, contents, binaries)
    print("Relocatable bundle paths verified")


if __name__ == "__main__":
    validate(Path(sys.argv[1]))
