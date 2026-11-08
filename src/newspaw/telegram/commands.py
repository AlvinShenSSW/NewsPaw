"""Owner-only command replies and local, explicitly scoped operations."""

import asyncio
import base64
import hashlib
import json
import logging
import re
import sqlite3
from contextlib import suppress
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta

import httpx

from ..config import parse_times
from ..credentials import CredentialError
from ..media.audio import MAX_SPEECH, MediaInputError
from ..media.newspaper import PaperError
from ..pipeline import PipelineError
from .client import TelegramError, TelegramSendError
from .outbox import _AUTOMATIC_ATTEMPTS, OutboxError, _clock, _json, _photo, send_lane_blocked
from .targets import TargetError
from .text import split_delivery_text

_SELECTOR = re.compile(r"[sa]:[A-Za-z][A-Za-z0-9_-]{0,79}")
_COMMAND = re.compile(r"/([a-z]+)(?:@([A-Za-z0-9_]{1,32}))?")
_COMMANDS = {
    "news",
    "search",
    "schedule",
    "pause",
    "resume",
    "status",
    "why",
    "x",
    "av",
    "paper",
    "listen",
}
_ACTIVE_JOBS = ("collecting", "editing", "preparing_media", "awaiting_delivery")
_BATCH = 8
_LOG = logging.getLogger(__name__)

_UI = {
    "en": {
        "denied": "This Bot cannot access that scope or brief.",
        "choose": "Choose a scope first. For example, /news followed by its code.",
        "none": "This Bot has no active news assignment.",
        "help": "Commands: /news /search /schedule /pause /resume /status /why /x /av /paper /listen",
        "paper": "Reply to a confirmed brief with /paper, optionally followed by 1 or 2 and item:1.",
        "media": "Please send your question as text.",
        "listen": "Reply to a confirmed briefing with /listen.",
        "voice_unavailable": "Local audio is unavailable for this language. Here is the briefing text.",
        "schedule": "Schedule ({zone}): {times}",
        "inherited": "This change would also retime a special account. Use Mac settings.",
        "bad_times": "Enter times as HH:MM,HH:MM.",
        "no_job": "No current job in this scope.",
        "status": "Current job: {status}",
        "pause": "This job is paused.",
        "resume": "This job is resumed.",
        "local_resume": "Review this job in Mac settings before resuming.",
        "bad_query": "Enter a search phrase of 1–120 characters.",
    },
    "zh-Hans": {
        "denied": "此 Bot 无权访问这个订阅、账号或简报。",
        "choose": "请先选择范围，例如发送 /news 加下方代码。",
        "none": "此 Bot 暂无启用的新闻分配。",
        "help": "命令：/news /search /schedule /pause /resume /status /why /x /av /paper /listen",
        "paper": "请回复一条已送达的简报发送 /paper，可加 1 或 2 和 item:1。",
        "media": "请用文字发送问题。",
        "listen": "请回复一条已送达的简报发送 /listen。",
        "voice_unavailable": "当前语言的本机语音不可用。以下是简报正文。",
        "schedule": "推送时间（{zone}）：{times}",
        "inherited": "修改会同时改变特别关注账号的时间，请在 Mac 设置中调整。",
        "bad_times": "请输入 HH:MM,HH:MM 格式的时间。",
        "no_job": "这个范围目前没有任务。",
        "status": "当前任务：{status}",
        "pause": "此任务已暂停。",
        "resume": "此任务已恢复。",
        "local_resume": "请先在 Mac 设置中检查此任务，再恢复。",
        "bad_query": "请输入 1–120 字的搜索词。",
    },
    "ja": {
        "denied": "この Bot には指定された範囲やニュースを読む権限がありません。",
        "choose": "先に範囲を選択してください。例：/news の後に下のコードを入力。",
        "none": "この Bot には有効なニュースの配信先設定がありません。",
        "help": "コマンド：/news /search /schedule /pause /resume /status /why /x /av /paper /listen",
        "paper": "配信済みニュースに /paper で返信してください。1 または 2 と item:1 を追加できます。",
        "media": "質問をテキストで送ってください。",
        "listen": "配信済みニュースに /listen で返信してください。",
        "voice_unavailable": "この言語の端末音声は利用できません。ニュースをテキストでお送りします。",
        "schedule": "配信時刻（{zone}）：{times}",
        "inherited": "特別フォロー中のアカウントにも影響します。Mac の設定で変更してください。",
        "bad_times": "時刻を HH:MM,HH:MM の形式で入力してください。",
        "no_job": "この範囲に現在のジョブはありません。",
        "status": "現在のジョブ：{status}",
        "pause": "このジョブを一時停止しました。",
        "resume": "このジョブを再開しました。",
        "local_resume": "Mac の設定でジョブを確認してから再開してください。",
        "bad_query": "1〜120 文字の検索語を入力してください。",
    },
}
_NEWS = {
    "en": (
        "No eligible local brief.",
        "No match in recent local briefs.",
        "Cited evidence",
        "Sources with coverage",
    ),
    "zh-Hans": ("本机暂无可用简报。", "近期本机简报中未找到结果。", "引用证据", "已有报道的来源"),
    "ja": (
        "この端末に閲覧できるニュースはありません。",
        "最近のニュースに該当する結果はありません。",
        "引用した情報源",
        "情報を取得できた情報源",
    ),
}


def initialize(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS command_replies (
            bot_id TEXT NOT NULL,generation INTEGER NOT NULL,update_id INTEGER NOT NULL,
            telegram_id INTEGER NOT NULL,chat_id INTEGER NOT NULL,
            context TEXT NOT NULL,parts TEXT NOT NULL,state TEXT NOT NULL,
            inflight_part INTEGER,backoff_until TEXT,
            PRIMARY KEY(bot_id,generation,update_id),
            FOREIGN KEY(bot_id,generation,update_id) REFERENCES bot_inbox(bot_id,generation,update_id)
        )"""
    )
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS command_one_inflight_bot
           ON command_replies(telegram_id) WHERE inflight_part IS NOT NULL"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS command_bot_backoff
           ON command_replies(telegram_id,backoff_until) WHERE backoff_until IS NOT NULL"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS inbox_pending ON bot_inbox(state) WHERE state='pending'"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS command_jobs_scope
           ON pipeline_jobs(subscription_id,account_key,created_at DESC)"""
    )
    db.execute(
        """CREATE INDEX IF NOT EXISTS delivery_message_binding ON delivery_targets(bot_id,chat_id)"""
    )


@dataclass(frozen=True)
class Scope:
    subscription: str
    account: str | None
    category: str
    partition: str
    remote_account: str | None
    name: str

    @property
    def code(self):
        return "a:" + self.account if self.account else "s:" + self.subscription

    def key(self):
        return [self.code, self.subscription, self.category, self.partition, self.remote_account]


class Commands:
    def __init__(self, outbox, *, clock=_clock, media=None):
        self.outbox = outbox
        self.pipeline = outbox.pipeline
        self.targets = outbox.targets
        self.registry = self.targets.registry
        self.store, self.db = outbox.store, outbox.db
        self.clock, self._task, self.media = clock, None, media

    def _scope(self, config, binding, code):
        if not isinstance(code, str) or not _SELECTOR.fullmatch(code):
            return None
        account = None
        identity = code[2:]
        if code[0] == "a":
            account = next((row for row in config["accounts"] if row["id"] == identity), None)
            if not account or account["priority"] != "special" or not account["remote_id"]:
                return None
            identity = account["subscription_id"]
        subscription = next((row for row in config["subscriptions"] if row["id"] == identity), None)
        if not subscription or not subscription["enabled"]:
            return None
        category = next(
            row for row in config["categories"] if row["id"] == subscription["category_id"]
        )
        try:
            self.targets.revalidate_target(
                identity, binding.bot_id, binding, account_id=account["id"] if account else None
            )
        except TargetError:
            return None
        return Scope(
            identity,
            account["id"] if account else None,
            category["id"],
            category["partition"],
            account["remote_id"] if account else None,
            "@" + account["handle"] if account else subscription["name"],
        )

    def _choices(self, config, binding, command):
        codes = [
            "s:" + row["id"] for row in config["subscriptions"] if binding.bot_id in row["bot_ids"]
        ]
        subscriptions = {row["id"]: row for row in config["subscriptions"]}
        for account in config["accounts"]:
            sub = subscriptions.get(account["subscription_id"])
            if not sub or account["priority"] != "special":
                continue
            targets = sub["bot_ids"] if account["bot_ids"] is None else account["bot_ids"]
            if binding.bot_id in targets:
                codes.append("a:" + account["id"])
        return [
            scope
            for code in codes
            if (scope := self._scope(config, binding, code)) and self._fits(command, scope)
        ]

    @staticmethod
    def _fits(command, scope):
        if command == "x":
            return scope.category in {"x", "x_adult"}
        if command == "av":
            return scope.category == "av"
        return True

    def _anchor(self, binding, message_id, *, briefing_only=False):
        key = (binding.bot_id, binding.chat_id, message_id)
        jobs = self.db.execute(
            """SELECT d.job_id,j.subscription_id,j.account_key,j.payload
               FROM delivery_targets d JOIN pipeline_jobs j ON j.id=d.job_id,json_each(d.parts) p
               WHERE d.bot_id=? AND d.chat_id=? AND json_extract(p.value,'$.message_id')=?
               AND json_extract(p.value,'$.state')='delivered' AND d.binding=? LIMIT 2""",
            (*key, _json(asdict(binding))),
        ).fetchall()
        replies = self.db.execute(
            """SELECT r.context FROM command_replies r,json_each(r.parts) p
               WHERE r.bot_id=? AND r.chat_id=? AND json_extract(p.value,'$.message_id')=?
               AND json_extract(p.value,'$.state')='delivered'
               AND r.generation=? AND r.telegram_id=? LIMIT 2""",
            (*key, binding.generation, binding.telegram_id),
        ).fetchall()
        if len(jobs) + len(replies) != 1 or (briefing_only and not jobs):
            return None
        if replies:
            context = json.loads(replies[0][0])
            if "scope" in context:
                return (
                    context["scope"][0],
                    context.get("job"),
                    context["scope"],
                    bool(context.get("needs_edition")),
                )
            return None
        job, subscription, account, payload = jobs[0]
        frozen = json.loads(json.loads(payload)["route"]["_effective"])
        code = "a:" + account if account else "s:" + subscription
        return (
            code,
            job,
            [
                code,
                subscription,
                frozen["category_id"],
                frozen["partition"],
                frozen["account"]["remote_id"] if account else None,
            ],
            True,
        )

    def _parse(self, payload, binding):
        value = payload.get("text", payload.get("caption", "")).strip()
        explicit_command = value.startswith("/")
        first, _, remaining = value.partition(" ")
        match = _COMMAND.fullmatch(first)
        if first.startswith("/"):
            if not match:
                return "help", None, ""
            command, handle = match.groups()
            if (
                handle
                and handle.casefold()
                != (self.registry.status(binding.bot_id)["username"] or "").casefold()
            ):
                return None, None, ""
            command = command if command in _COMMANDS else "help"
            value = remaining.strip()
        else:
            command = "search"
        if "media" in payload:
            if command != "search":
                return "unsupported_media", None, ""
            if not explicit_command:
                return "media", None, ""
            command = "media"
        first, _, remaining = value.partition(" ")
        if first.startswith(("s:", "a:")):
            return command, first, remaining.strip()
        return command, None, value

    def _jobs(self, scope):
        return (
            row[0]
            for row in self.db.execute(
                """SELECT id FROM pipeline_jobs WHERE subscription_id=? AND account_key=?
                   AND partition=? AND cancelled=0 AND stage='awaiting_delivery'
                   ORDER BY created_at DESC,rowid DESC LIMIT 12""",
                (scope.subscription, scope.account or "", scope.partition),
            )
        )

    def _edition(self, job, scope):
        try:
            route, text, _ = self.pipeline.delivery_input(job)
        except PipelineError:
            return None
        if (route.subscription_id, route.account_id) != (scope.subscription, scope.account):
            return None
        result = self.pipeline.editorial.get(self.pipeline._edition_id(job))["result"]
        return result, text

    def _news(self, command, scope, job, query, context, config):
        absent, no_match, sources_label, coverage_label = _NEWS[context["locale"]]
        if command == "search" and not 1 <= len(query) <= 120:
            context.update(locale=config["ui_locale"], language="ui")
            return _UI[context["locale"]]["bad_query"]
        candidates = [job] if job else (() if command == "why" else self._jobs(scope))
        for candidate in candidates:
            edition = self._edition(candidate, scope)
            if edition is None:
                continue
            result, text = edition
            if command == "search":
                term = query.casefold()
                matching = [
                    item
                    for item in result["items"]
                    if term in (item["title"] + "\n" + item["body"]).casefold()
                ][:5]
                if not matching:
                    continue
                lines = []
                for item in matching:
                    source = item["sources"][0]
                    lines.extend([item["title"], source["published_at"], source["url"]])
                text = "\n".join(lines)
            elif command == "why":
                citations = {
                    (source["source"], source["published_at"], source["url"])
                    for item in [*result["items"], *result["conflicts"]]
                    for source in item["sources"]
                }
                covered = {
                    identity
                    for row in result["coverage"]
                    if row["eligible_count"] and row.get("coverage_complete", True)
                    for identity in row["source_ids"]
                }
                total = {identity for row in result["coverage"] for identity in row["source_ids"]}
                lines = [sources_label, f"{coverage_label}: {len(covered)}/{len(total)}"]
                for source, published, url in sorted(citations)[:20]:
                    lines.extend([f"{source} · {published}", url])
                text = "\n".join(lines)
            context.update(job=candidate, needs_edition=True)
            return text
        return no_match if command == "search" else absent

    def _schedule(self, config, revision, scope, query, ui):
        sub = next(row for row in config["subscriptions"] if row["id"] == scope.subscription)
        owner = sub
        if scope.account:
            owner = next(row for row in config["accounts"] if row["id"] == scope.account)
        if query:
            try:
                times = parse_times(query)
            except ValueError:
                return ui["bad_times"]
            if times != owner["times"]:
                if not scope.account and any(
                    a["priority"] == "special"
                    and a["subscription_id"] == scope.subscription
                    and a["times"] is None
                    for a in config["accounts"]
                ):
                    return ui["inherited"]
                owner["times"] = times
                self.store._save_config_tx(config, revision)
        times = sub["times"] if owner["times"] is None else owner["times"]
        return ui["schedule"].format(zone=sub["timezone"], times=", ".join(times) or "—")

    def _management(self, command, scope, job, ui, context, now):
        if job is None:
            stages = ",".join("?" for _ in _ACTIVE_JOBS)
            row = self.db.execute(
                f"""SELECT id FROM pipeline_jobs WHERE subscription_id=? AND account_key=?
                   AND partition=? AND cancelled=0 AND stage IN ({stages})
                   ORDER BY created_at DESC,rowid DESC LIMIT 1""",
                (scope.subscription, scope.account or "", scope.partition, *_ACTIVE_JOBS),
            ).fetchone()
            job = row[0] if row else None
        view = self.pipeline.get(job) if job is not None else None
        if view and (view["subscription_id"], view["account_id"], view["partition"]) != (
            scope.subscription,
            scope.account,
            scope.partition,
        ):
            return ui["denied"], None
        if job is not None:
            context["job"] = job
        if command == "status":
            occurrence = self.db.execute(
                """SELECT o.status FROM schedule_occurrences o JOIN schedule_scopes s
                   ON s.id=o.scope_id WHERE s.subscription_id=? AND s.account_id IS ?
                   AND s.active=1 ORDER BY o.updated_at DESC,o.target_at DESC LIMIT 1""",
                (scope.subscription, scope.account),
            ).fetchone()
            if not view and not occurrence:
                return ui["no_job"], None
            statuses = {
                "en": (
                    "Collecting",
                    "Summarizing",
                    "Preparing media",
                    "Ready",
                    "Paused",
                    "Needs attention",
                ),
                "zh-Hans": ("采集中", "整理中", "准备媒体", "已就绪", "已暂停", "待处理"),
                "ja": (
                    "収集中",
                    "要約中",
                    "メディア準備中",
                    "配信準備済み",
                    "一時停止中",
                    "確認が必要",
                ),
            }[context["locale"]]
            index = (
                {
                    "collecting": 0,
                    "editing": 1,
                    "preparing_media": 2,
                    "awaiting_delivery": 3,
                    "paused": 4,
                }.get(view["status"], 5)
                if view
                else 5
            )
            status = statuses[index]
            if occurrence:
                status += " · " + self._schedule_status(context["locale"], occurrence[0])
            return ui["status"].format(status=status), None
        if not view or view["cancelled"] or view["stage"] not in _ACTIVE_JOBS:
            return ui["no_job"], None
        if command == "resume" and (
            not view["paused"]
            or view["status"] in {"blocked", "outcome_unknown", "inflight"}
            or (view["model"] and view["model"]["state"] in {"blocked", "outcome_unknown"})
        ):
            return ui["local_resume"], None
        paused = command == "pause"
        self.pipeline.set_paused_tx(job, paused, now)
        return ui[command], job if paused else None

    @staticmethod
    def _schedule_status(locale, state):
        labels = {
            "en": ("Scheduled", "Preparing", "Late", "Delivered", "Skipped", "Needs attention"),
            "zh-Hans": ("已计划", "准备中", "延迟", "已送达", "已跳过", "待处理"),
            "ja": ("予定済み", "準備中", "遅延", "配信済み", "スキップ", "確認が必要"),
        }
        index = {
            "planned": 0,
            "preparing": 1,
            "late": 2,
            "delivered": 3,
            "skipped": 4,
            "superseded": 4,
            "cancelled": 4,
        }.get(state, 5)
        return labels[locale][index]

    def _reply(self, revision, config, payload, binding, now):
        ui = _UI[config["ui_locale"]]
        context = dict(locale=config["ui_locale"], language="ui")
        command, explicit, query = self._parse(payload, binding)
        if command is None:
            return context, "", None
        if command == "unsupported_media":
            return context, ui["media"], None
        if command == "help" or (query and command not in {"search", "schedule", "media", "paper"}):
            return context, ui["help"], None
        attachment = command in {"media", "listen"}
        anchor = None
        reply_id = payload.get("reply_to_message_id")
        if reply_id is not None:
            anchor = self._anchor(binding, reply_id, briefing_only=attachment)
            if not anchor or (explicit and explicit != anchor[0]):
                return context, ui["denied"], None
        job = anchor[1] if anchor else None
        code = explicit or (anchor[0] if anchor else None)
        if (command == "listen" and not job) or (
            command == "media" and self.media is not None and not (explicit or job)
        ):
            return context, ui[command], None
        if code:
            scope = self._scope(config, binding, code)
            if (
                not scope
                or not self._fits(command, scope)
                or (anchor and anchor[2] is not None and anchor[2] != scope.key())
            ):
                return context, ui["denied"], None
        else:
            choices = self._choices(config, binding, command)
            if len(choices) != 1:
                if not choices:
                    return context, ui["none"], None
                page = choices[:15]
                context.update(choices=[[s.key(), s.name] for s in page], selector_command=command)
                lines = [ui["choose"], *(f"{s.code} · {s.name}" for s in page)]
                return context, "\n".join(lines), None
            scope = choices[0]
        context["scope"] = scope.key()
        if attachment:
            if scope.partition != "normal" or self.media is None:
                return context, ui[command], None
            if job:
                if self._edition(job, scope) is None:
                    return context, ui["denied"], None
                context.update(job=job, needs_edition=True, media_anchor=reply_id)
            try:
                plan = self.media.plan(payload.get("media"), listen=command == "listen")
            except MediaInputError:
                if command == "listen" and job:
                    edition = self._edition(job, scope)
                    if edition:
                        context.update(locale=config["news_output_locale"], language="news")
                        return (
                            context,
                            _UI[context["locale"]]["voice_unavailable"] + "\n\n" + edition[1],
                            None,
                        )
                return context, ui[command], None
            plan["expires"] = (now + timedelta(minutes=3)).isoformat()
            context.update(locale=config["news_output_locale"], language="news", media=plan)
            return context, ui[command], None
        if command == "paper":
            if not anchor or not anchor[3] or job is None:
                return context, ui["paper"], None
            options = (
                re.fullmatch(r"(?:([12])(?: item:([1-9][0-9]?))?|item:([1-9][0-9]?))", query)
                if query
                else None
            )
            if query and options is None:
                return context, ui["paper"], None
            edition = self._edition(job, scope)
            if edition is None:
                return context, ui["denied"], None
            page, item, only_item = options.groups() if options else (None, None, None)
            context.update(
                locale=config["news_output_locale"],
                language="news",
                job=job,
                needs_edition=True,
                paper=dict(
                    pages=int(page) if page else 1 if only_item else None,
                    item=int(item or only_item) if item or only_item else None,
                    deadline=(now + timedelta(minutes=2)).isoformat(),
                ),
            )
            return context, edition[1], None
        if command in {"news", "search", "why", "x", "av"}:
            context.update(locale=config["news_output_locale"], language="news")
            return context, self._news(command, scope, job, query, context, config), None
        if command == "schedule":
            return context, self._schedule(config, revision, scope, query, ui), None
        if command in {"pause", "resume", "status"}:
            text, paused_job = self._management(command, scope, job, ui, context, now)
            return context, text, paused_job
        return context, ui[command], None

    def _plan(self, key, now):
        paused_job = None
        with self.store._write():
            row = self.db.execute(
                "SELECT payload,state FROM bot_inbox WHERE bot_id=? AND generation=? AND update_id=?",
                key,
            ).fetchone()
            if row is None or row[1] != "pending":
                return
            payload = json.loads(row[0])
            binding = self._binding(key, chat=payload.get("chat_id"))
            if binding is None or payload.get("sender_id") != binding.owner_id:
                self._clear_input(key, "stale")
                return
            revision, config = self.store.load_config()
            context, text, paused_job = self._reply(revision, config, payload, binding, now)
            try:
                parts = split_delivery_text(text)
            except ValueError:
                parts = []
            if not parts or len(parts) > 80 or len(text.encode()) > 512 * 1024:
                self._clear_input(key, "handled")
                return
            self.db.execute(
                "INSERT INTO command_replies VALUES (?,?,?,?,?,?,?,'pending',NULL,NULL)",
                (
                    *key,
                    binding.telegram_id,
                    binding.chat_id,
                    _json(context),
                    _json([dict(text=part, state="pending", attempts=0) for part in parts]),
                ),
            )
            self._clear_input(key, "handled")
        if paused_job is not None:
            self.pipeline.notify_paused(paused_job)

    def _clear_input(self, key, state):
        self.db.execute(
            "UPDATE bot_inbox SET state=?,payload='{}' WHERE bot_id=? AND generation=? AND update_id=?",
            (state, *key),
        )

    def _binding(self, key, *, chat, telegram_id=None):
        try:
            binding = self.registry.snapshot(key[0])
        except TelegramError:
            return None
        if (
            binding.generation != key[1]
            or binding.chat_id != chat
            or (telegram_id is not None and binding.telegram_id != telegram_id)
        ):
            return None
        return binding

    def _allowed(self, context, binding):
        _, config = self.store.load_config()
        locale = "ui_locale" if context["language"] == "ui" else "news_output_locale"
        if config[locale] != context["locale"]:
            return False
        if "choices" in context:
            choices = self._choices(config, binding, context["selector_command"])[:15]
            return context["choices"] == [[s.key(), s.name] for s in choices]
        if "scope" not in context:
            return True
        scope = self._scope(config, binding, context["scope"][0])
        if not scope or scope.key() != context["scope"]:
            return False
        if context.get("needs_media_policy") and (
            self.media is None or not self.media.allowed(context["media"])
        ):
            return False
        if anchor_id := context.get("media_anchor"):
            anchor = self._anchor(binding, anchor_id, briefing_only=True)
            if not anchor or anchor[1] != context["job"] or anchor[2] != scope.key():
                return False
        if context.get("needs_edition"):
            return self._edition(context["job"], scope) is not None
        return True

    def _row(self, key):
        return self.db.execute(
            """SELECT telegram_id,chat_id,context,parts,state,inflight_part,backoff_until
               FROM command_replies WHERE bot_id=? AND generation=? AND update_id=?""",
            key,
        ).fetchone()

    def _save(self, key, parts, state, *, inflight=None, backoff=None):
        if state != "pending":
            for part in parts:
                part.pop("text", None)
                part.pop("caption", None)
                part.pop("data", None)
            self.db.execute(
                """UPDATE command_replies SET context=json_remove(context,'$.media.file_id')
                   WHERE bot_id=? AND generation=? AND update_id=?""",
                key,
            )
        self.db.execute(
            """UPDATE command_replies SET parts=?,state=?,inflight_part=?,backoff_until=?
               WHERE bot_id=? AND generation=? AND update_id=?""",
            (_json(parts), state, inflight, backoff, *key),
        )

    def _finish(self, key, ordinal, *, message_id=None, error=None):
        with self.store._write():
            remote, chat, _, parts, _, inflight, _ = self._row(key)
            if inflight != ordinal:
                return
            parts = json.loads(parts)
            part = parts[ordinal]
            state, backoff = "pending", None
            if error is None:
                part.update(state="delivered", message_id=message_id)
                if ordinal + 1 == len(parts):
                    state = "completed"
            elif error.kind == "rate_limited":
                backoff = (self.clock() + timedelta(seconds=error.retry_after)).isoformat()
                if part["attempts"] >= _AUTOMATIC_ATTEMPTS:
                    state = part["state"] = "failed"
                else:
                    part["state"] = "pending"
            elif error.kind in {
                "payload_rejected",
                "token_revoked",
                "forbidden",
                "rate_limit_invalid",
            }:
                state = part["state"] = "failed"
                if error.kind in {"token_revoked", "forbidden"}:
                    binding = self._binding(key, chat=chat, telegram_id=remote)
                    if binding is not None:
                        self.registry.revoke_send_binding(binding, error.kind)
            else:
                state = part["state"] = "outcome_unknown"
            self._save(key, parts, state, backoff=backoff)

    async def _prepare_media(self, key, binding, context, client):
        plan = context["media"]
        expiry = datetime.fromisoformat(plan["expires"])

        def allowed():
            current = self._binding(key, chat=binding.chat_id, telegram_id=binding.telegram_id)
            return current == binding and self._allowed(context, current)

        def live():
            return (
                allowed()
                and self.clock() < expiry
                and self.media is not None
                and self.media.allowed(plan)
            )

        _, config = self.store.load_config()
        text = _UI[config["ui_locale"]]["media"]
        audio = None
        produced = False
        next_context = context
        if allowed():
            scope = self._scope(config, binding, context["scope"][0])
            if plan["kind"] == "listen":
                edition = self._edition(context["job"], scope)
                if edition:
                    result, text = edition
                    spoken = " ".join(
                        f"{item['title']}. {item['body']}" for item in result["items"][:8]
                    )
                    try:
                        if not live():
                            raise MediaInputError("voice_unavailable")
                        audio = await self.media.speech.synthesize(spoken, result["locale"])
                        if (
                            not live()
                            or not isinstance(audio, bytes)
                            or not 1 <= len(audio) <= MAX_SPEECH
                        ):
                            raise MediaInputError("voice_unavailable")
                        produced = True
                    except (MediaInputError, OSError):
                        audio = None
                        text = _UI[context["locale"]]["voice_unavailable"] + "\n\n" + text
            else:
                try:
                    if client is None or not live():
                        raise MediaInputError("media_capability_unavailable")
                    phrase = await self.media.query(key, plan, client, live)
                    if not live():
                        raise MediaInputError("media_scope_changed")
                    next_context = context.copy()
                    text = self._news(
                        "search", scope, context.get("job"), phrase, next_context, config
                    )
                    produced = True
                except (MediaInputError, TelegramError):
                    next_context = {**context, "locale": config["ui_locale"], "language": "ui"}
        with self.store._write():
            _, _, stored, serialized, state, inflight, _ = self._row(key)
            if state != "pending" or inflight is not None or json.loads(stored) != context:
                return
            if not allowed():
                self._save(key, json.loads(serialized), "stale")
                return
            if plan["kind"] != "listen":
                context = next_context
            if produced and not live():
                self._save(key, json.loads(serialized), "stale")
                return
            try:
                parts = [
                    dict(text=value, state="pending", attempts=0)
                    for value in split_delivery_text(text)
                ]
            except ValueError:
                parts = []
            if not parts or len(parts) > 80 or len(text.encode()) > 512 * 1024:
                self._save(key, json.loads(serialized), "failed")
                return
            if audio:
                parts.append(
                    dict(
                        kind="audio",
                        state="pending",
                        attempts=0,
                        data=base64.b64encode(audio).decode("ascii"),
                        sha256=hashlib.sha256(audio).hexdigest(),
                    )
                )
            context["media"] = {k: v for k, v in plan.items() if k != "file_id"}
            context["media_ready"] = True
            context["needs_media_policy"] = produced
            self.db.execute(
                "UPDATE command_replies SET context=?,parts=? WHERE bot_id=? AND generation=? AND update_id=?",
                (_json(context), _json(parts), *key),
            )

    async def _prepare_paper(self, key, binding, context):
        paper = context["paper"]
        service = self.pipeline.newspapers
        photos = []

        def authorized():
            current = self._binding(key, chat=binding.chat_id, telegram_id=binding.telegram_id)
            return current == binding and self._allowed(context, current)

        if service is not None and authorized():
            _, config = self.store.load_config()
            scope = self._scope(config, binding, context["scope"][0])
            edition = self._edition(context["job"], scope) if scope else None
            if edition:
                try:
                    generated = await service.prepare(
                        self.pipeline._edition_id(context["job"]),
                        edition[0],
                        scope.partition,
                        datetime.fromisoformat(paper["deadline"]),
                        authorized,
                        item_number=paper["item"],
                        page_count=paper["pages"],
                    )
                    if generated:
                        photos = [_photo(part) for part in generated]
                except (PaperError, OutboxError):
                    pass
        with self.store._write():
            _, _, stored, serialized, state, inflight, _ = self._row(key)
            if state != "pending" or inflight is not None or json.loads(stored) != context:
                return
            parts = json.loads(serialized)
            if not authorized():
                self._save(key, parts, "stale")
                return
            if self.clock() < datetime.fromisoformat(paper["deadline"]):
                parts.extend({**photo, "state": "pending", "attempts": 0} for photo in photos)
            context["paper_ready"] = True
            self.db.execute(
                "UPDATE command_replies SET context=?,parts=? WHERE bot_id=? AND generation=? AND update_id=?",
                (_json(context), _json(parts), *key),
            )

    async def _dispatch(self, key):
        row = self._row(key)
        if row is None:
            return
        remote, chat = row[:2]
        binding = self._binding(key, chat=chat, telegram_id=remote)
        context = json.loads(row[2])
        if binding is not None and context.get("paper") and not context.get("paper_ready"):
            await self._prepare_paper(key, binding, context)
            row = self._row(key)
        if row[4] != "pending" or row[5] is not None:
            return
        client, asset = None, None
        try:
            if binding is not None:
                try:
                    token = await asyncio.to_thread(
                        self.targets.credentials.backend.read, binding.credential_ref
                    )
                    client = self.outbox.client_factory(token)
                except (CredentialError, TelegramError, OSError):
                    pass
            planned = json.loads(row[2])
            if binding is not None and planned.get("media") and not planned.get("media_ready"):
                await self._prepare_media(key, binding, planned, client)
                row = self._row(key)
            if row[4] != "pending" or row[5] is not None:
                return
            parts = json.loads(row[3])
            selected = next(i for i, part in enumerate(parts) if part["state"] == "pending")
            pending = parts[selected]
            if client is not None and pending.get("kind") == "photo":
                with suppress(OutboxError):
                    asset = await self.outbox._asset(pending)
            with self.store._write():
                remote, chat, context, parts, state, inflight, _ = self._row(key)
                if state != "pending" or inflight is not None:
                    return
                parts = json.loads(parts)
                current = self._binding(key, chat=chat, telegram_id=remote)
                current_context = json.loads(context)
                if (
                    current is None
                    or current != binding
                    or not self._allowed(current_context, current)
                ):
                    self._save(key, parts, "stale")
                    return
                if client is None:
                    self._save(key, parts, "failed")
                    return
                if send_lane_blocked(self.db, remote, self.clock()):
                    return
                ordinal = next(i for i, p in enumerate(parts) if p["state"] == "pending")
                part = parts[ordinal]
                if ordinal != selected or part != pending:
                    return
                if part.get("kind") == "photo" and (
                    asset is None
                    or self.clock() >= datetime.fromisoformat(current_context["paper"]["deadline"])
                ):
                    self._save(key, parts, "failed")
                    return
                audio = None
                if part.get("kind") == "audio":
                    plan = current_context["media"]
                    try:
                        audio = base64.b64decode(part["data"], validate=True)
                    except (ValueError, TypeError):
                        audio = None
                    if (
                        audio is None
                        or not 1 <= len(audio) <= MAX_SPEECH
                        or hashlib.sha256(audio).hexdigest() != part["sha256"]
                        or self.clock() >= datetime.fromisoformat(plan["expires"])
                    ):
                        self._save(key, parts, "failed")
                        return
                part.update(state="inflight", attempts=part["attempts"] + 1)
                self._save(key, parts, "pending", inflight=ordinal)
            try:
                if audio is not None:
                    message_id = await client.send_audio(binding, audio)
                elif part.get("kind") == "photo":
                    message_id = await client.send_photo(
                        binding, asset, part["mime"], part["caption"]
                    )
                else:
                    message_id = await client.send_message(binding, part["text"])
            except asyncio.CancelledError:
                self._finish(key, ordinal, error=TelegramSendError("cancelled_after_intent"))
                raise
            except TelegramSendError as exc:
                self._finish(key, ordinal, error=exc)
            else:
                self._finish(key, ordinal, message_id=message_id)
        finally:
            if client is not None:
                with suppress(httpx.HTTPError, OSError):
                    await client.close()

    async def tick(self):
        keys = self.db.execute(
            "SELECT bot_id,generation,update_id FROM bot_inbox WHERE state='pending' ORDER BY rowid LIMIT ?",
            (_BATCH,),
        ).fetchall()
        for key in keys:
            self._plan(key, self.clock())
        now = self.clock().isoformat()
        keys = self.db.execute(
            """SELECT r.bot_id,r.generation,r.update_id FROM command_replies r
               WHERE r.state='pending' AND r.inflight_part IS NULL AND NOT EXISTS (
                   SELECT 1 FROM delivery_targets d WHERE d.telegram_id=r.telegram_id
                   AND (d.inflight_part IS NOT NULL OR d.backoff_until>?)
               ) AND NOT EXISTS (
                   SELECT 1 FROM command_replies c WHERE c.telegram_id=r.telegram_id
                   AND (c.inflight_part IS NOT NULL OR c.backoff_until>?)
               ) ORDER BY r.rowid LIMIT ?""",
            (now, now, _BATCH),
        ).fetchall()
        for key in keys:
            await self._dispatch(key)

    def recover_interrupted(self):
        with self.store._write():
            rows = self.db.execute(
                """SELECT bot_id,generation,update_id,parts,inflight_part
                   FROM command_replies WHERE inflight_part IS NOT NULL"""
            ).fetchall()
            for bot, generation, update, parts, inflight in rows:
                parts = json.loads(parts)
                parts[inflight]["state"] = "outcome_unknown"
                self._save((bot, generation, update), parts, "outcome_unknown")

    async def _run(self):
        while True:
            try:
                await self.tick()
            except (sqlite3.Error, OSError):
                _LOG.warning("telegram_command_storage_unavailable")
            await asyncio.sleep(0.5)

    def start(self):
        self._task = asyncio.create_task(self._run())

    async def close(self):
        if self._task is not None:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
