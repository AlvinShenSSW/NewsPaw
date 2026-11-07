import plistlib
import subprocess
from pathlib import Path

import pytest

from newspaw import service


@pytest.fixture
def layout(tmp_path, monkeypatch):
    home = tmp_path / "Home With Spaces"
    project = tmp_path / "Project With Spaces"
    python = project / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.write_text("#!/bin/sh\n")
    python.chmod(0o700)
    config = project / "private config.env"
    config.write_text("TELEGRAM_BOT_TOKEN=never-copy-this-secret\n")
    monkeypatch.setattr(service.sys, "platform", "darwin")
    monkeypatch.setattr(service.Path, "home", lambda: home)
    monkeypatch.setattr(service.os, "getuid", lambda: 501)
    return home, project, config


def fake_launchctl(monkeypatch, *, loaded=False, fail_command=None):
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        assert kwargs["timeout"] == 20
        assert "shell" not in kwargs
        command = args[1]
        if command == "print":
            return subprocess.CompletedProcess(
                args,
                0 if loaded else 113,
                stdout="state = running\n pid = 42\n SECRET_TOKEN = secret-value\n",
                stderr="",
            )
        return subprocess.CompletedProcess(
            args, 5 if command == fail_command else 0, stdout="", stderr="secret-value"
        )

    monkeypatch.setattr(service.subprocess, "run", run)
    return calls


def test_plist_paths_are_separate_arguments_and_environment_is_allowlisted():
    config = service.build_plist(
        Path("/Projects/News Paw"), Path("/Secrets/config env"), Path("/Users/A B")
    )
    assert config["ProgramArguments"] == [
        "/Projects/News Paw/.venv/bin/python",
        "-m",
        "newspaw",
        "--config",
        "/Secrets/config env",
        "run",
    ]
    assert set(config["EnvironmentVariables"]) == {"PATH"}
    assert "/opt/homebrew/bin" in config["EnvironmentVariables"]["PATH"]
    assert config["KeepAlive"] is True
    assert config["ThrottleInterval"] == 30
    assert plistlib.loads(plistlib.dumps(config)) == config


def test_install_writes_private_plist_and_loads_it(layout, monkeypatch):
    home, project, config = layout
    calls = fake_launchctl(monkeypatch)
    result = service.manage_service("install", project, config)
    plist_path = home / "Library/LaunchAgents/io.newspaw.agent.plist"
    assert "Installed and loaded" in result
    assert plist_path.stat().st_mode & 0o777 == 0o600
    assert b"never-copy-this-secret" not in plist_path.read_bytes()
    assert calls[-1] == ["/bin/launchctl", "bootstrap", "gui/501", str(plist_path)]
    assert (home / "Library/Logs/NewsPaw/stderr.log").stat().st_mode & 0o777 == 0o600


def test_stop_disables_and_boots_out_instead_of_killing_kept_alive_process(layout, monkeypatch):
    _, project, config = layout
    calls = fake_launchctl(monkeypatch, loaded=True)
    assert "disabled" in service.manage_service("stop", project, config)
    assert [args[1] for args in calls] == ["print", "disable", "bootout"]


def test_status_never_echoes_arbitrary_launchctl_environment(layout, monkeypatch):
    _, project, config = layout
    fake_launchctl(monkeypatch, loaded=True)
    result = service.manage_service("status", project, config)
    assert "pid: 42" in result
    assert "state: running" in result
    assert "SECRET" not in result and "secret-value" not in result


def test_uninstall_preserves_plist_when_unload_fails(layout, monkeypatch):
    home, project, config = layout
    plist_path = home / "Library/LaunchAgents/io.newspaw.agent.plist"
    plist_path.parent.mkdir(parents=True)
    plist_path.write_bytes(b"previous configuration")
    fake_launchctl(monkeypatch, loaded=True, fail_command="bootout")
    with pytest.raises(service.ServiceError) as error:
        service.manage_service("uninstall", project, config)
    assert plist_path.read_bytes() == b"previous configuration"
    assert "secret-value" not in str(error.value)


def test_failed_initial_install_removes_unusable_plist(layout, monkeypatch):
    home, project, config = layout
    fake_launchctl(monkeypatch, fail_command="bootstrap")
    with pytest.raises(service.ServiceError, match="Installation failed"):
        service.manage_service("install", project, config)
    assert not (home / "Library/LaunchAgents/io.newspaw.agent.plist").exists()


def test_start_reenables_existing_installation(layout, monkeypatch):
    home, project, config = layout
    plist_path = home / "Library/LaunchAgents/io.newspaw.agent.plist"
    plist_path.parent.mkdir(parents=True)
    plist_path.write_bytes(b"test")
    calls = fake_launchctl(monkeypatch)
    service.manage_service("start", project, config)
    assert [args[1] for args in calls] == ["print", "enable", "bootstrap"]


def test_install_rejects_missing_config_before_mutating_service(layout, monkeypatch):
    home, project, config = layout
    config.unlink()
    calls = fake_launchctl(monkeypatch)
    with pytest.raises(service.ServiceError, match="Configuration file"):
        service.manage_service("install", project, config)
    assert calls == []
    assert not (home / "Library/LaunchAgents").exists()
