"""Install the current project as a per-user macOS LaunchAgent.

No credentials are copied to launchd. The agent reads its private configuration
file at process startup, and launchctl output is never returned wholesale.
"""

from __future__ import annotations

import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

LABEL = "io.newspaw.agent"
LAUNCHCTL = "/bin/launchctl"


class ServiceError(RuntimeError):
    """An installation or launchctl operation could not be completed."""


def service_log_directory(home_dir: Path) -> Path:
    return home_dir / "Library" / "Logs" / "NewsPaw"


def build_plist(project_dir: Path, config_path: Path, home_dir: Path) -> dict:
    """Build launchd configuration without reading files or running commands.

    Arguments must be absolute; keeping argv as a list also supports spaces in
    the project, configuration, and home directory names.
    """
    if not all(p.is_absolute() for p in (project_dir, config_path, home_dir)):
        raise ValueError("Service paths must be absolute.")
    log_dir = service_log_directory(home_dir)
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(project_dir / ".venv" / "bin" / "python"),
            "-m",
            "newspaw",
            "--config",
            str(config_path),
            "run",
        ],
        "WorkingDirectory": str(project_dir),
        "EnvironmentVariables": {
            "PATH": ":".join(
                [
                    str(home_dir / ".local" / "bin"),
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                ]
            )
        },
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "ExitTimeOut": 20,
        "ProcessType": "Background",
        "StandardOutPath": str(log_dir / "stdout.log"),
        "StandardErrorPath": str(log_dir / "stderr.log"),
        "Umask": 0o077,
    }


def _run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            [LAUNCHCTL, *args],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ServiceError(f"launchctl {args[0]} could not complete.") from exc
    if check and result.returncode:
        # launchctl print can contain environment variables inherited from the
        # user's session; never copy stdout/stderr into diagnostics.
        raise ServiceError(
            f"launchctl {args[0]} failed (exit {result.returncode}). "
            "Run this command from your logged-in macOS desktop account."
        )
    return result


def _inspect(target: str) -> subprocess.CompletedProcess[str] | None:
    result = _run("print", target, check=False)
    if result.returncode == 0:
        return result
    if result.returncode in (3, 113):  # ESRCH / launchctl service-not-found
        return None
    raise ServiceError(f"Cannot inspect NewsPaw (launchctl exit {result.returncode}).")


def _atomic_write(path: Path, contents: bytes) -> None:
    """Replace an owned plist atomically, always with private permissions."""
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
        temporary_path.chmod(0o600)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def _prepare_logs(log_dir: Path) -> None:
    log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_dir.chmod(0o700)
    for filename in ("stdout.log", "stderr.log"):
        log_path = log_dir / filename
        descriptor = os.open(
            log_path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600
        )
        try:
            info = os.fstat(descriptor)
            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                raise OSError("unsafe_service_log")
            os.fchmod(descriptor, 0o600)
        finally:
            os.close(descriptor)


def _install(
    project_dir: Path, config_path: Path, home_dir: Path, plist_path: Path, domain: str
) -> str:
    python_path = project_dir / ".venv" / "bin" / "python"
    if not python_path.is_file() or not os.access(python_path, os.X_OK):
        raise ServiceError("Missing project virtual environment. Run uv sync first.")
    if not config_path.is_file():
        raise ServiceError("Configuration file does not exist. Complete local setup first.")
    contents = plistlib.dumps(build_plist(project_dir, config_path, home_dir))
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    _prepare_logs(service_log_directory(home_dir))
    target = f"{domain}/{LABEL}"
    previous = plist_path.read_bytes() if plist_path.exists() else None
    was_loaded = _inspect(target) is not None
    if was_loaded:
        _run("bootout", target)
    try:
        _atomic_write(plist_path, contents)
        _run("enable", target)
        _run("bootstrap", domain, str(plist_path))
    except (ServiceError, OSError) as exc:
        # Keep an existing installation usable when a replacement cannot load.
        try:
            if previous is None:
                plist_path.unlink(missing_ok=True)
            else:
                _atomic_write(plist_path, previous)
                if was_loaded:
                    _run("bootstrap", domain, str(plist_path))
        except (ServiceError, OSError):
            raise ServiceError(
                "Installation failed and the previous service could not be restored. "
                "Check local configuration, then run service install again."
            ) from exc
        raise ServiceError(
            "Installation failed; the previous plist was restored if one existed. "
            "Check local configuration and desktop session, then retry."
        ) from exc
    return (
        f"Installed and loaded {LABEL}. Starts at login and restarts after exit. "
        "Use service status and the NewsPaw logs to verify application health."
    )


def manage_service(action: str, project_dir: Path, config_path: Path) -> str:
    """Manage NewsPaw for the current macOS user without root privileges.

    install/start explicitly load the service. stop disables it persistently and
    boots it out, so KeepAlive cannot immediately restart it. uninstall leaves
    the private configuration, database, and logs intact.
    """
    if action not in {"install", "start", "stop", "status", "uninstall"}:
        raise ValueError(f"Unknown service action: {action}")
    if sys.platform != "darwin":
        raise ServiceError("The background service installer requires macOS.")
    home_dir = Path.home().resolve()
    project_dir = project_dir.expanduser().resolve()
    config_path = config_path.expanduser().resolve()
    plist_path = home_dir / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{LABEL}"
    try:
        if action == "install":
            return _install(project_dir, config_path, home_dir, plist_path, domain)

        state = _inspect(target)
        if action == "status":
            if state is None:
                return "NewsPaw is stopped." if plist_path.exists() else "NewsPaw is not installed."
            # Return only known status fields, never arbitrary launchctl output.
            fields = []
            for name in ("state", "pid", "last exit code"):
                match = re.search(rf"^\s*{re.escape(name)} = ([\w -]+)$", state.stdout, re.M)
                if match:
                    fields.append(f"{name}: {match.group(1)}")
            return "NewsPaw is loaded" + (f" ({', '.join(fields)})." if fields else ".")

        if action == "start":
            if not plist_path.is_file():
                raise ServiceError("NewsPaw is not installed. Run service install first.")
            _run("enable", target)
            if state is None:
                _run("bootstrap", domain, str(plist_path))
            else:
                _run("kickstart", target)
            return "NewsPaw start requested. Use service status to check it."

        if action == "stop":
            if state is None and not plist_path.exists():
                return "NewsPaw is not installed."
            _run("disable", target)
            if state is not None:
                _run("bootout", target)
            return "NewsPaw is stopped and disabled until service start or install."

        # Unload before removing the file; if bootout fails, retain the plist.
        if state is not None:
            _run("bootout", target)
        plist_path.unlink(missing_ok=True)
        return "NewsPaw service removed. Configuration, data, and logs are preserved."
    except OSError as exc:
        raise ServiceError(
            "Could not access the NewsPaw service files. Check file permissions."
        ) from exc
