"""Same-user Unix socket control. No TCP, commands, or remote administration."""

from __future__ import annotations

import asyncio
import ctypes
import errno
import fcntl
import json
import logging
import os
import re
import socket
import stat
import struct
import sys
from contextlib import suppress
from dataclasses import asdict
from logging.handlers import RotatingFileHandler
from pathlib import Path

from .budget import BudgetError, BudgetLedger
from .connectors.web_search import WebSearch
from .credentials import CredentialError
from .errors import code_of, detail
from .media.image_provider import ImageProvider
from .media.input_service import MediaCommands
from .media.newspaper import MacOCR
from .media.paper_service import Newspapers
from .media.source_images import AssetStore, SourceImages
from .media.speech_provider import TranscriptionProvider
from .operations import Operations
from .pipeline import Pipeline
from .providers import ProbeService, ProfileRegistry, ProviderError
from .readiness import readiness
from .scheduler import Scheduler
from .source_catalog import catalog
from .source_manager import SourceError, SourceManager
from .subscriptions import Subscriptions
from .telegram.check_send import TestSends
from .telegram.commands import Commands
from .telegram.outbox import Outbox
from .telegram.registry import BotRegistry, TelegramError
from .telegram.targets import TargetManager
from .x.accounts import XDirectory
from .x.alerts import Alerts
from .x.digests import XDigests
from .x.timelines import Timelines
from .x.video import Videos

MAX_FRAME = 8 * 1024 * 1024
AUTO_PROBE_HOLD = 10_000  # $0.01 for one short capability check (E10 contract §2).
_LOG = logging.getLogger(__name__)
# Only a bounded ASCII name may become an error domain; anything else stays "protocol".
_OP_NAME = re.compile(r"[a-z][a-z0-9_]{0,31}(?:\.[a-z][a-z0-9_]{0,31}){0,3}")
OPERATIONS = {
    "ops.diagnostics": (set(), set()),
    "ops.support_snapshot": (set(), set()),
    "ops.export_settings": (set(), set()),
    "ops.preview_import": ({"portable"}, set()),
    "ops.apply_import": ({"portable", "digest", "revision"}, set()),
    "ops.verify_backup": ({"name"}, set()),
    "ops.cleanup": (set(), {"apply", "limit"}),
    "service.status": (set(), set()),
    "setup.readiness": (set(), set()),
    "service.stop": (set(), set()),
    "schedule.status": (set(), {"limit"}),
    "subscriptions.send_now": ({"subscription_id"}, set()),
    "media.policy": (set(), set()),
    "media.configure": ({"settings", "revision"}, set()),
    "newspaper.policy": (set(), set()),
    "newspaper.configure": ({"settings", "revision"}, set()),
    "schedule.configure": ({"settings", "revision"}, set()),
    "schedule.resolve": ({"occurrence_id", "action"}, set()),
    "delivery.status": ({"job_id"}, {"bot_id"}),
    "delivery.requeue_target": ({"job_id", "bot_id"}, set()),
    "delivery.resolve": (
        {"job_id", "bot_id", "ordinal", "action"},
        {"acknowledge_duplicate_send", "message_id"},
    ),
    "x.accounts.list": (set(), set()),
    "x.accounts.add": ({"handle", "revision"}, {"partition"}),
    "x.accounts.partition_impact": ({"account_id"}, set()),
    "x.accounts.status": ({"account_id"}, set()),
    "x.accounts.verify": ({"account_id", "request_id", "revision"}, set()),
    "x.accounts.classify": ({"account_id", "partition", "revision"}, set()),
    "x.accounts.route": (
        {"account_id", "subscription_id", "priority", "revision"},
        {"include_in_aggregate", "post_types", "overrides"},
    ),
    "x.accounts.remove": ({"account_id", "revision"}, set()),
    "x.video.policy": (set(), set()),
    "x.video.save": ({"settings", "revision"}, set()),
    "x.video.inspect": ({"request_id", "job_id", "post_id"}, set()),
    "x.video.candidates": (set(), set()),
    "x.video.status": ({"request_id"}, set()),
    "x.alerts.status": (set(), set()),
    "x.alerts.save": ({"settings", "revision"}, set()),
    "x.lists.list": (set(), set()),
    "x.lists.add": ({"value", "partition", "revision"}, {"default_adult"}),
    "x.lists.refresh": ({"list_id", "request_id", "revision"}, {"page_size", "max_pages"}),
    "x.operation": ({"request_id"}, set()),
    "x.posts.begin": (
        {"scan_id", "kind", "scope", "revision"},
        {
            "page_size",
            "include_original",
            "include_quotes",
            "include_replies",
            "include_reposts",
            "fresh",
        },
    ),
    "x.posts.advance": ({"scan_id", "step_id"}, set()),
    "x.posts.coverage": ({"kind", "scope"}, set()),
    "x.posts.status": ({"scan_id"}, set()),
    "x.posts.stop": ({"scan_id"}, set()),
    "x.posts.list": ({"kind", "scope"}, {"limit"}),
    "x.posts.purge_expired": (set(), {"limit"}),
    "jobs.list": (set(), {"limit"}),
    "jobs.get": ({"job_id"}, set()),
    "jobs.audit": ({"job_id"}, {"after", "limit"}),
    "jobs.pause": ({"job_id"}, set()),
    "jobs.resume": ({"job_id"}, {"acknowledge_duplicate_charge"}),
    "jobs.cancel": ({"job_id"}, set()),
    "targets.preview": ({"subscription_id"}, {"account_id"}),
    "targets.set_subscription": ({"subscription_id", "bot_ids", "revision"}, set()),
    "targets.set_category": ({"category_id", "bot_ids", "revision"}, set()),
    "targets.set_account": ({"account_id", "bot_ids", "revision"}, set()),
    "targets.account_partition": ({"account_id", "partition", "revision"}, set()),
    "targets.adult_permission": ({"bot_id", "allowed", "revision"}, set()),
    "targets.bot_impact": ({"bot_id"}, set()),
    "targets.delete_bot": ({"bot_id", "revision"}, set()),
    "subscriptions.preview": ({"draft", "revision"}, set()),
    "subscriptions.save": ({"draft", "revision"}, {"enable"}),
    "subscriptions.pause_category": ({"category_id", "revision"}, set()),
    "sources.catalog": (set(), set()),
    "sources.list": (set(), set()),
    "sources.discover": ({"url"}, set()),
    "sources.save": ({"source", "revision"}, set()),
    "sources.assign": ({"source_id", "subscriptions", "revision"}, set()),
    "sources.delete": ({"source_id", "revision"}, set()),
    "sources.preview": ({"source_id"}, set()),
    "sources.routes": ({"source_id"}, set()),
    "sources.impact": ({"source_id", "action"}, set()),
    "sources.import_opml": ({"content", "revision"}, set()),
    "sources.search.policy": (set(), set()),
    "sources.search.configure": ({"profile_id", "revision"}, set()),
    "sources.search.run": ({"subscription_id", "request_id", "revision", "hold_units"}, set()),
    "sources.search.status": ({"request_id"}, set()),
    "bots.list": (set(), set()),
    "bots.test_send": ({"bot_id", "generation", "request_id"}, set()),
    "bots.test_status": ({"bot_id", "generation", "request_id"}, set()),
    "bots.status": ({"bot_id"}, set()),
    "bots.verify": ({"bot_id"}, {"generation"}),
    "bots.pair_code": ({"bot_id"}, {"generation"}),
    "bots.action": ({"bot_id", "action"}, {"generation"}),
    "bots.delete": ({"bot_id", "revision"}, set()),
    "models.status": ({"profile_id"}, set()),
    "models.health": (set(), set()),
    "models.probe": ({"probe_id", "profile_id", "capability", "hold_units"}, {"revision"}),
    "budget.get": (set(), set()),
    "budget.save": ({"document", "revision"}, set()),
    "config.get": (set(), set()),
    "config.save": ({"document", "revision"}, set()),
    "route.preview": ({"subscription_id"}, {"account_id", "style"}),
    "credentials.set": ({"kind", "id", "value", "revision"}, set()),
    "credentials.remove": ({"kind", "id", "revision"}, set()),
    "credentials.status": (set(), set()),
    "credentials.cleanup": (set(), set()),
    "legacy.preferences": ({"path", "revision"}, set()),
    "legacy.secrets": ({"path", "revision"}, set()),
}


def peer_uid(sock):
    if sys.platform == "darwin":
        fn = ctypes.CDLL(None, use_errno=True).getpeereid
        fn.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        fn.restype = ctypes.c_int
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if fn(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise ValueError("peer_unavailable")
        return uid.value
    if sys.platform.startswith("linux"):
        return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    raise ValueError("peer_unavailable")


def acquire_control_lock(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unsafe_control_directory")
    fd = os.open(directory / "agent.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("unsafe_control_lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("already_running") from None
        return fd
    except BaseException:
        os.close(fd)
        raise


class ControlServer:
    def __init__(self, directory: Path, credentials, *, log_directory=None):
        self.directory = Path(directory).expanduser().absolute()
        self.path = self.directory / "control.sock"
        self.credentials = credentials
        self.media = MediaCommands(credentials.store, credentials.backend)
        self.probes = ProbeService(
            credentials.store,
            credentials.backend,
            stt_factory=TranscriptionProvider,
            stt_fixture=self.media.speech.probe_wav,
            image_factory=ImageProvider,
        )
        self.bots = BotRegistry(credentials.store, credentials.backend)
        self.bot_tests = TestSends(self.bots)
        self.sources = SourceManager(credentials)
        self.subscriptions = Subscriptions(credentials, self.sources, self.bots)
        self.web_search = WebSearch(credentials.store, credentials.backend)
        self.targets = TargetManager(credentials, self.bots)
        self.x = XDirectory(credentials, self.targets)
        self.x_posts = Timelines(self.x)
        assets = AssetStore(self.directory / "media")
        ocr = MacOCR(Path(sys.executable).resolve().with_name("newspaw-ocr"))
        self.newspapers = Newspapers(credentials.store, credentials.backend, assets, ocr)
        self.pipeline = Pipeline(
            credentials.store,
            credentials.backend,
            source_images=SourceImages(credentials.store, assets),
            newspapers=self.newspapers,
            x_digests=XDigests(self.x_posts),
        )
        self.outbox = Outbox(self.pipeline, self.targets, asset_resolver=assets.read)
        self.scheduler = Scheduler(self.pipeline, self.outbox)
        self.alerts = Alerts(self.pipeline, self.outbox)
        self.videos = Videos(self.pipeline, self.x)
        self.outbox.alert_guard = self.alerts.guard
        self.scheduler.alerts = self.alerts
        self.commands = Commands(self.outbox, media=self.media)
        self.operations = Operations(
            credentials.store,
            self.directory,
            process_status=lambda: (
                "stopping"
                if self._stop_requested.is_set()
                else "running"
                if self._server is not None
                else "stopped"
            ),
            purge_x=self.x_posts.purge_expired,
            log_directory=log_directory,
        )
        self._server = None
        self._lock_fd = None
        self._handlers = set()
        self._socket_identity = None
        self._stop_requested = asyncio.Event()
        self._background = set()

    async def start(self):
        if self._server is not None:
            raise ValueError("already_running")
        self._stop_requested.clear()
        if self._lock_fd is None:
            self._lock_fd = acquire_control_lock(self.directory)
        try:
            if self.path.exists() or self.path.is_symlink():
                info = self.path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    raise ValueError("unsafe_control_socket")
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(0.2)
                    if probe.connect_ex(str(self.path)) != errno.ECONNREFUSED:
                        raise ValueError("control_socket_in_use")
                self.path.unlink()
            self._server = await asyncio.start_unix_server(
                self._handle, path=self.path, limit=MAX_FRAME + 1, start_serving=False
            )
            self.path.chmod(0o600)
            self._socket_identity = self.path.stat().st_ino
            await self.credentials.cleanup()
            BudgetLedger(self.credentials.store).recover_inflight()
            self.web_search.recover_interrupted()
            ProfileRegistry(self.credentials.store).recover_interrupted()
            self.pipeline.recover_interrupted()
            self.outbox.recover_interrupted()
            self.commands.recover_interrupted()
            self.bot_tests.recover_interrupted()
            self.media.recover_interrupted()
            self.newspapers.recover_interrupted()
            self.x.recover_interrupted()
            self.x_posts.recover_interrupted()
            self.videos.recover_interrupted()
            await self._server.start_serving()
            await self.bots.start()
            self.scheduler.start()
            self.commands.start()
        except BaseException:
            await self.close()
            raise

    async def close(self):
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        await self.commands.close()
        await self.scheduler.close()
        if self._handlers:
            await asyncio.gather(*self._handlers, return_exceptions=True)
        # After the last handler: none can start another background check now.
        while self._background:
            for task in tuple(self._background):
                task.cancel()
            await asyncio.gather(*self._background, return_exceptions=True)
        await self.bots.close()
        await self.pipeline.close()
        await self.credentials.drain()
        if self._socket_identity is not None:
            try:
                if self.path.lstat().st_ino == self._socket_identity:
                    self.path.unlink()
            except FileNotFoundError:
                pass
            self._socket_identity = None
        if self._lock_fd is not None:
            os.close(self._lock_fd)
            self._lock_fd = None

    def _verify_soon(self, profile_id, capabilities):
        """E10 contract §2: check a capability as soon as it becomes needed, in the background.

        The probe ID is bound to the profile generation (which changes with the key), so a
        repeated save or configure reuses the earlier result instead of paying again.
        """

        async def run():
            registry = ProfileRegistry(self.credentials.store)
            for capability in capabilities:
                try:
                    _, generation = registry.profile(profile_id)
                    if registry.status(profile_id)[capability]["state"] == "verified":
                        continue
                    await self.probes.probe(
                        f"auto.{profile_id}.{capability}.g{generation}",
                        profile_id,
                        capability,
                        AUTO_PROBE_HOLD,
                    )
                except (CredentialError, BudgetError, ProviderError) as exc:
                    _LOG.warning("Automatic %s check failed (%s)", capability, type(exc).__name__)

        task = asyncio.create_task(run())
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    async def wait_for_stop(self):
        await self._stop_requested.wait()

    async def _dispatch(self, data):
        if not isinstance(data, dict) or not isinstance(data.get("op"), str):
            raise CredentialError("invalid_request")
        op = data["op"]
        if op not in OPERATIONS:
            raise CredentialError("unknown_operation")
        required, optional = OPERATIONS[op]
        keys = set(data) - {"op"}
        if not required <= keys or keys - required - optional:
            error = CredentialError("invalid_request")
            error.field = (
                min(required - keys) if required - keys else min(keys - required - optional)
            )
            raise error
        if op == "service.stop":
            self._stop_requested.set()
        if op in {"service.status", "service.stop"}:
            return {
                "protocol_version": 1,
                "state": "stopping" if self._stop_requested.is_set() else "running",
                "operations": sorted(OPERATIONS),
            }
        if self._stop_requested.is_set():
            raise CredentialError("service_stopping")
        manager, store = self.credentials, self.credentials.store
        if op == "setup.readiness":
            return readiness(store, ProfileRegistry(store))
        if op == "ops.diagnostics":
            return self.operations.diagnostics()
        if op == "ops.support_snapshot":
            return self.operations.support_snapshot()
        if op == "ops.export_settings":
            return self.operations.export_settings()
        if op == "ops.preview_import":
            return self.operations.preview_import(data["portable"])
        if op == "ops.apply_import":
            return self.operations.apply_import(data["portable"], data["digest"], data["revision"])
        if op == "ops.verify_backup":
            return await asyncio.to_thread(self.operations.verify_backup, data["name"])
        if op == "ops.cleanup":
            return self.operations.cleanup(
                apply=data.get("apply", False), limit=data.get("limit", 100)
            )
        if op == "media.policy":
            return self.media.policy()
        if op == "media.configure":
            result = self.media.configure(data["settings"], data["revision"])
            for capability in ("vision", "stt"):
                if result["settings"][capability + "_profile"] is not None:
                    self._verify_soon(result["settings"][capability + "_profile"], [capability])
            return result
        if op == "newspaper.policy":
            return self.newspapers.policy()
        if op == "newspaper.configure":
            result = self.newspapers.configure(data["settings"], data["revision"])
            settings = result["settings"]
            if settings["enabled"]:
                for role, capability in (
                    ("generation_profile", "image"),
                    ("backup_profile", "image"),
                    ("vision_profile", "vision"),
                ):
                    if settings[role] is not None:
                        self._verify_soon(settings[role], [capability])
            return result
        if op == "schedule.status":
            return self.scheduler.status(limit=data.get("limit", 25))
        if op == "subscriptions.send_now":
            return self.scheduler.send_now(data["subscription_id"])
        if op == "schedule.configure":
            return self.scheduler.configure(data["settings"], data["revision"])
        if op == "schedule.resolve":
            return self.scheduler.resolve(data["occurrence_id"], data["action"])
        if op == "delivery.status":
            return self.outbox.status(data["job_id"], bot_id=data.get("bot_id"))
        if op == "delivery.requeue_target":
            return self.outbox.requeue_target(data["job_id"], data["bot_id"])
        if op == "delivery.resolve":
            return self.outbox.resolve(
                data["job_id"],
                data["bot_id"],
                data["ordinal"],
                data["action"],
                acknowledge_duplicate_send=data.get("acknowledge_duplicate_send", False),
                message_id=data.get("message_id"),
            )
        if op == "x.accounts.list":
            return self.x.accounts()
        if op == "x.accounts.add":
            return await self.x.add_account(
                data["handle"], data["revision"], partition=data.get("partition")
            )
        if op == "x.accounts.partition_impact":
            return self.x.partition_impact(data["account_id"])
        if op == "x.accounts.status":
            return self.x.account_status(data["account_id"])
        if op == "x.accounts.verify":
            return await self.x.verify(data["account_id"], data["request_id"], data["revision"])
        if op == "x.accounts.classify":
            return await self.x.classify(data["account_id"], data["partition"], data["revision"])
        if op == "x.accounts.route":
            return await self.x.set_route(
                data["account_id"],
                data["subscription_id"],
                data["priority"],
                data["revision"],
                include_in_aggregate=data.get("include_in_aggregate"),
                post_types=data.get("post_types"),
                overrides=data.get("overrides"),
            )
        if op == "x.accounts.remove":
            return await self.x.remove_account(data["account_id"], data["revision"])
        if op == "x.video.policy":
            return self.videos.policy()
        if op == "x.video.save":
            return self.videos.configure(data["settings"], data["revision"])
        if op == "x.video.inspect":
            return await self.videos.inspect(data["request_id"], data["job_id"], data["post_id"])
        if op == "x.video.candidates":
            return self.videos.candidates()
        if op == "x.video.status":
            return self.videos.status(data["request_id"])
        if op == "x.alerts.status":
            return self.alerts.status()
        if op == "x.alerts.save":
            return self.alerts.configure(data["settings"], data["revision"])
        if op == "x.lists.list":
            return self.x.lists()
        if op == "x.lists.add":
            return self.x.add_list(
                data["value"],
                data["partition"],
                data["revision"],
                default_adult=data.get("default_adult", False),
            )
        if op == "x.lists.refresh":
            return await self.x.refresh_list(
                data["list_id"],
                data["request_id"],
                data["revision"],
                page_size=data.get("page_size", 25),
                max_pages=data.get("max_pages", 4),
            )
        if op == "x.operation":
            return self.x.operation(data["request_id"])
        if op == "x.posts.begin":
            return self.x_posts.begin(**{key: value for key, value in data.items() if key != "op"})
        if op == "x.posts.advance":
            return await self.x_posts.advance(data["scan_id"], data["step_id"])
        if op == "x.posts.coverage":
            return self.x_posts.coverage(data["kind"], data["scope"])
        if op == "x.posts.status":
            return self.x_posts.status(data["scan_id"])
        if op == "x.posts.stop":
            return self.x_posts.stop(data["scan_id"])
        if op == "x.posts.list":
            return self.x_posts.posts(data["kind"], data["scope"], limit=data.get("limit", 50))
        if op == "x.posts.purge_expired":
            return self.x_posts.purge_expired(limit=data.get("limit", 100))
        if op == "jobs.list":
            return self.pipeline.list(data.get("limit", 25))
        if op == "jobs.get":
            return self.pipeline.get(data["job_id"])
        if op == "jobs.audit":
            return self.pipeline.audit(
                data["job_id"], after=data.get("after", 0), limit=data.get("limit", 50)
            )
        if op == "jobs.pause":
            return self.pipeline.pause(data["job_id"])
        if op == "jobs.resume":
            return self.pipeline.resume(
                data["job_id"],
                acknowledge_duplicate_charge=data.get("acknowledge_duplicate_charge", False),
            )
        if op == "jobs.cancel":
            return self.pipeline.cancel(data["job_id"])
        if op == "targets.preview":
            return self.targets.preview(data["subscription_id"], account_id=data.get("account_id"))
        if op == "targets.set_subscription":
            return await self.targets.set_subscription(
                data["subscription_id"], data["bot_ids"], data["revision"]
            )
        if op == "targets.set_category":
            return await self.targets.set_category(
                data["category_id"], data["bot_ids"], data["revision"]
            )
        if op == "targets.set_account":
            return await self.targets.set_account(
                data["account_id"], data["bot_ids"], data["revision"]
            )
        if op == "targets.account_partition":
            return await self.targets.account_partition(
                data["account_id"], data["partition"], data["revision"]
            )
        if op == "targets.adult_permission":
            return await self.targets.adult_permission(
                data["bot_id"], data["allowed"], data["revision"]
            )
        if op == "targets.bot_impact":
            return self.targets.bot_impact(data["bot_id"])
        if op == "targets.delete_bot":
            return await self.targets.delete_bot(data["bot_id"], data["revision"])
        if op == "subscriptions.preview":
            return self.subscriptions.preview(data["draft"], data["revision"])
        if op == "subscriptions.save":
            return await self.subscriptions.save(
                data["draft"], data["revision"], enable=data.get("enable", False)
            )
        if op == "subscriptions.pause_category":
            return await self.subscriptions.pause_category(data["category_id"], data["revision"])
        if op == "sources.catalog":
            return catalog()
        if op == "sources.list":
            return self.sources.list()
        if op == "sources.discover":
            return await self.sources.discover(data["url"])
        if op == "sources.save":
            return await self.sources.save(data["source"], data["revision"])
        if op == "sources.assign":
            return await self.sources.assign(
                data["source_id"], data["subscriptions"], data["revision"]
            )
        if op == "sources.delete":
            return await self.sources.delete(data["source_id"], data["revision"])
        if op == "sources.preview":
            return await self.sources.preview(data["source_id"])
        if op == "sources.impact":
            return self.sources.impact(data["source_id"], data["action"])
        if op == "sources.routes":
            return self.sources.routes(data["source_id"])
        if op == "sources.import_opml":
            return await self.sources.import_opml(data["content"], data["revision"])
        if op == "sources.search.policy":
            return self.web_search.policy()
        if op == "sources.search.configure":
            return self.web_search.configure(data["profile_id"], data["revision"])
        if op == "sources.search.run":
            return await self.web_search.run(
                data["subscription_id"], data["request_id"], data["revision"], data["hold_units"]
            )
        if op == "sources.search.status":
            return self.web_search.status(data["request_id"])
        if op == "bots.list":
            return self.bots.list()
        if op == "bots.status":
            return self.bots.status(data["bot_id"])
        if op == "bots.test_status":
            return self.bot_tests.status(data["bot_id"], data["generation"], data["request_id"])
        if op == "bots.test_send":
            return await self.bot_tests.send(data["bot_id"], data["generation"], data["request_id"])
        if op == "bots.verify":
            return await self.bots.verify(data["bot_id"], generation=data.get("generation"))
        if op == "bots.pair_code":
            return self.bots.pair_code(data["bot_id"], generation=data.get("generation"))
        if op == "bots.action":
            return self.bots.action(
                data["bot_id"], data["action"], generation=data.get("generation")
            )
        if op == "bots.delete":
            return await self.bots.delete(data["bot_id"], manager, data["revision"])
        if op == "models.health":
            return {"profiles": self.pipeline.runner.health()}
        if op == "models.status":
            return ProfileRegistry(store).status(data["profile_id"])
        if op == "models.probe":
            return await self.probes.probe(
                data["probe_id"],
                data["profile_id"],
                data["capability"],
                data["hold_units"],
                revision=data.get("revision"),
            )
        if op in {"budget.get", "budget.save"}:
            ledger = BudgetLedger(store)
            if op == "budget.get":
                revision, document = ledger.policy()
                return {"revision": revision, "document": document, "report": ledger.report()}
            return {"revision": ledger.configure(data["document"], data["revision"])}
        if op == "config.get":
            revision, document = store.load_config()
            return {"revision": revision, "document": document}
        if op == "config.save":
            return await manager.save_config(data["document"], data["revision"])
        if op == "route.preview":
            route = store.preview_route(
                data["subscription_id"], account_id=data.get("account_id"), style=data.get("style")
            )
            return {
                **{k: v for k, v in asdict(route).items() if not k.startswith("_")},
                "effective": route.effective,
                "explanation": route.explanation,
            }
        if op == "credentials.set":
            result = await manager.set(data["kind"], data["id"], data["value"], data["revision"])
            if data["kind"] == "model_profiles" and result["revision"] != data["revision"]:
                self._verify_soon(data["id"], ["text"])
            return result
        if op == "credentials.remove":
            return await manager.remove(data["kind"], data["id"], data["revision"])
        if op == "credentials.status":
            return await manager.status()
        if op == "credentials.cleanup":
            return await manager.cleanup()
        if op == "legacy.preferences":
            return await manager.import_preferences(data["path"], data["revision"])
        return await manager.import_secrets(data["path"], data["revision"])

    @staticmethod
    def _failure(code, domain, field=None):
        return {"ok": False, "error": code, "error_detail": detail(code, domain, field)}

    async def _handle(self, reader, writer):
        task = asyncio.current_task()
        if len(self._handlers) >= 16:
            writer.close()
            return
        self._handlers.add(task)
        domain, op = "protocol", None
        try:
            try:
                if peer_uid(writer.get_extra_info("socket")) != os.getuid():
                    raise CredentialError("peer_denied")
                async with asyncio.timeout(10):
                    raw = await reader.readline()
                if not raw.endswith(b"\n") or len(raw) > MAX_FRAME:
                    raise CredentialError("invalid_request")
                try:
                    data = json.loads(raw)
                except ValueError:
                    raise CredentialError("invalid_request") from None
                if (
                    isinstance(data, dict)
                    and isinstance(data.get("op"), str)
                    and _OP_NAME.fullmatch(data["op"])
                ):
                    op = data["op"]
                    domain = op.split(".", 1)[0]
                result = await self._dispatch(data)
                response = {"ok": True, "result": result}
            except (CredentialError, BudgetError, ProviderError, TelegramError, SourceError) as exc:
                response = self._failure(str(exc), domain, getattr(exc, "field", None))
            except ValueError as exc:
                field = getattr(exc, "field", None)
                response = self._failure(code_of(exc, "invalid_request"), domain, field)
            except Exception as exc:
                logged = op if op in OPERATIONS else domain
                _LOG.warning("Control %s failed (%s)", logged, type(exc).__name__)
                response = self._failure("internal_error", domain, getattr(exc, "field", None))
            encoded = json.dumps(response, ensure_ascii=False).encode() + b"\n"
            if len(encoded) > MAX_FRAME:
                too_large = self._failure("response_too_large", domain)
                encoded = json.dumps(too_large).encode() + b"\n"
            writer.write(encoded)
            async with asyncio.timeout(10):
                await writer.drain()
        except (ConnectionError, TimeoutError):
            pass
        finally:
            writer.close()
            with suppress(ConnectionError):
                await writer.wait_closed()
            self._handlers.discard(task)


async def serve_control(directory):
    from .credentials import CredentialManager, MacKeychain
    from .service import _prepare_logs, service_log_directory
    from .store import Store

    directory = Path(directory).expanduser().absolute()
    lock_fd = acquire_control_lock(directory)
    store = None
    server = None
    handler = None
    log_directory = service_log_directory(Path.home().resolve())
    try:
        if os.getenv("NEWSPAW_BUNDLED_RESIDENT") == "1":
            try:
                if log_directory.is_symlink():
                    raise OSError("unsafe_log_directory")
                _prepare_logs(log_directory)
                handler = RotatingFileHandler(
                    log_directory / "stderr.log",
                    maxBytes=1_048_576,
                    backupCount=3,
                    encoding="utf-8",
                )
                handler.setLevel(logging.WARNING)
                handler.setFormatter(
                    logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
                )
                logging.getLogger().addHandler(handler)
            except OSError:
                pass
        store = Store(directory / "newspaw.sqlite3")
        server = ControlServer(
            directory,
            CredentialManager(store, MacKeychain()),
            log_directory=log_directory,
        )
        server._lock_fd = lock_fd
        lock_fd = None
        await server.start()
        await server.wait_for_stop()
    finally:
        if server is not None:
            await server.close()
        if store is not None:
            store.close()
        if handler is not None:
            logging.getLogger().removeHandler(handler)
            handler.close()
        if lock_fd is not None:
            os.close(lock_fd)
