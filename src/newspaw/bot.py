"""Private Telegram interface and scheduled news delivery."""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import io
import logging
import time
from datetime import UTC, datetime
from zoneinfo import ZoneInfo

from telegram import Bot, BotCommand, Update
from telegram.error import TelegramError
from telegram.ext import (
    AIORateLimiter,
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .ai import AIError, AIService
from .config import ConfigError, Settings, parse_times, parse_topics
from .news import Article, NewsError, NewsService
from .schedule import due_slot
from .store import Store

log = logging.getLogger(__name__)
MAX_MEDIA_BYTES = 19 * 1024 * 1024
HELP = """🐾 NewsPaw 已连接

/news — 获取订阅主题的最新新闻
/search 关键词 — 找新闻
/topics — 查看主题；/topics AI;科技 修改主题
/schedule — 查看时间；/schedule 09:00,18:00 修改时间
/voice on 或 off — 开关新闻语音播报（Mac 本机合成）
/pause /resume — 暂停或恢复定时推送
/status — 查看服务状态

也可以直接发文字、图片或 3 分钟内的语音来找新闻。
图片理解、语音识别和智能摘要需要配置模型 API。
图片不会被当作已证实的新闻；结果以来源链接为准。"""


def split_text(text: str, limit: int = 3500) -> list[str]:
    """Keep Telegram's UTF-16 length limit, including emoji and astral glyphs."""
    chunks, chunk, size = [], [], 0
    for char in text:
        width = len(char.encode("utf-16-le")) // 2
        if size + width > limit:
            chunks.append("".join(chunk))
            chunk, size = [], 0
        chunk.append(char)
        size += width
    if chunk:
        chunks.append("".join(chunk))
    return chunks


async def send_text(bot: Bot, chat_id: int, text: str) -> None:
    for chunk in split_text(text):
        await bot.send_message(chat_id, chunk)


def article_text(article: Article, index: int, timezone: str) -> str:
    date = (
        article.published_at.astimezone(ZoneInfo(timezone)).strftime("%m-%d %H:%M")
        if article.published_at
        else "发布时间未知"
    )
    summary = f"\n{article.summary[:450]}" if article.summary else ""
    return (
        f"{index}. {article.title[:250]}\n{article.source[:100]} · {date}{summary}\n{article.url}"
    )


class NewsBot:
    def __init__(self, settings: Settings, store: Store, news: NewsService, ai: AIService):
        self.settings, self.store, self.news, self.ai = settings, store, news, ai
        self.delivery_lock = asyncio.Lock()
        self.next_retry = 0.0

    @property
    def owner_id(self) -> int | None:
        stored = self.store.get("owner_id")
        return self.settings.owner_id or (int(stored) if stored else None)

    @property
    def topics(self) -> list[str]:
        return parse_topics(self.store.get("topics", ";".join(self.settings.topics)))

    @property
    def times(self) -> list[str]:
        return parse_times(self.store.get("times", ",".join(self.settings.times)))

    @property
    def voice_enabled(self) -> bool:
        return self.store.get("voice", str(self.settings.voice_digest).lower()) == "true"

    async def authorize(self, update: Update) -> bool:
        if not update.effective_chat or update.effective_chat.type != "private":
            return False
        if not update.effective_user or update.effective_user.id != self.owner_id:
            if update.effective_message:
                await update.effective_message.reply_text(
                    "此 bot 仅供主人使用。首次连接请发送 /pair 本机配置中的配对码。"
                )
            return False
        self.store.set("chat_id", str(update.effective_chat.id))
        return True

    async def pair(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not update.effective_chat or update.effective_chat.type != "private":
            return
        if not update.effective_user or not update.effective_message:
            return
        if self.owner_id is not None:
            if await self.authorize(update):
                await update.effective_message.reply_text("已经完成配对。\n" + HELP)
            return
        candidate = " ".join(context.args)
        expected = self.settings.pairing_code
        if not expected or not hmac.compare_digest(candidate.encode(), expected.encode()):
            await update.effective_message.reply_text(
                "配对码不正确，请查看本机 .env 的 PAIRING_CODE。"
            )
            return
        self.store.set("owner_id", str(update.effective_user.id))
        self.store.set("chat_id", str(update.effective_chat.id))
        # Avoid replaying pre-pairing scheduled editions on initial setup.
        self.skip_current_slot()
        with contextlib.suppress(TelegramError):
            await update.effective_message.delete()
        await context.bot.send_message(update.effective_chat.id, "配对成功。\n" + HELP)

    def skip_current_slot(self) -> None:
        slot = due_slot(
            datetime.now(UTC), self.times, self.settings.timezone, self.settings.catchup_hours
        )
        if slot:
            self.store.set("last_slot", slot)

    async def start(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if await self.authorize(update):
            await update.effective_message.reply_text(HELP)

    async def status(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not await self.authorize(update):
            return
        state = "已暂停" if self.store.get("paused") == "true" else "运行中"
        await update.effective_message.reply_text(
            f"🐾 {state}\n主题：{'；'.join(self.topics)}\n"
            f"推送：{', '.join(self.times)}（{self.settings.timezone}）\n"
            f"智能摘要/图片/语音识别：{'已配置' if self.ai.enabled else '未配置 API Key'}\n"
            f"语音播报：{'开' if self.voice_enabled else '关'}\n"
            f"最近定时推送：{self.store.get('last_delivery', '尚无')}\n"
            f"最近定时任务：{self.store.get('last_outcome', '尚无')}\n"
            "常驻需要 Mac 已登录、保持唤醒且能够联网。"
        )

    async def configure(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not await self.authorize(update):
            return
        command = update.effective_message.text.split()[0].split("@")[0][1:]
        arg = " ".join(context.args)
        try:
            if command == "topics":
                if arg:
                    self.store.set("topics", ";".join(parse_topics(arg)))
                reply = "订阅主题：" + "；".join(self.topics)
            elif command == "schedule":
                if arg:
                    self.store.set("times", ",".join(parse_times(arg)))
                    self.skip_current_slot()
                reply = f"推送时间：{', '.join(self.times)}（{self.settings.timezone}）"
            elif command == "voice":
                if arg not in {"on", "off"}:
                    reply = "用 /voice on 或 /voice off 设置 Mac 本机语音播报。"
                else:
                    self.store.set("voice", str(arg == "on").lower())
                    reply = "语音播报已" + ("开启（AI 合成语音）。" if arg == "on" else "关闭。")
            else:
                self.store.set("paused", str(command == "pause").lower())
                if command == "resume":
                    self.skip_current_slot()
                reply = "定时推送已" + ("暂停。" if command == "pause" else "恢复。")
        except ConfigError as exc:
            reply = str(exc)
        await update.effective_message.reply_text(reply)

    async def deliver(
        self,
        bot: Bot,
        chat_id: int,
        articles: list[Article],
        *,
        query: str = "",
        track: bool = False,
    ) -> None:
        summary = ""
        if self.ai.enabled:
            try:
                summary = await self.ai.summarize(articles, query=query)
            except AIError:
                log.warning("AI summary unavailable; delivering source cards")
                await send_text(bot, chat_id, "智能摘要暂时不可用，以下为新闻来源的标题和摘要。")
        if summary:
            await send_text(bot, chat_id, "🐾 新闻摘要（基于来源标题和 RSS 摘要）\n\n" + summary)
        for index, article in enumerate(articles, 1):
            text = article_text(article, index, self.settings.timezone)
            sent = False
            if article.image_url and len(text.encode("utf-16-le")) // 2 <= 1000:
                try:
                    await bot.send_photo(chat_id, article.image_url, caption=text)
                    sent = True
                except TelegramError:
                    log.info("Source image unavailable; using text card")
            if not sent:
                await send_text(bot, chat_id, text)
            if track:
                self.store.mark_sent(chat_id, article)
        if self.voice_enabled:
            narration = summary or "。".join(article.title for article in articles)
            try:
                audio = await self.ai.speak(narration)
                await bot.send_audio(
                    chat_id,
                    audio=io.BytesIO(audio),
                    filename="newspaw.mp3",
                    title="NewsPaw 新闻播报",
                    caption="Mac 本机合成语音；原始来源见上方链接。",
                )
            except (AIError, TelegramError):
                log.warning("Voice delivery unavailable; text already delivered")
                await send_text(bot, chat_id, "语音播报暂时不可用，文字新闻已送达。")

    async def fetch_and_send(self, bot: Bot, chat_id: int, query: str = "") -> bool:
        if query:
            articles = await self.news.search(query[:500], self.settings.digest_size)
        else:
            candidates = await self.news.latest(self.topics, self.settings.digest_size * 4)
            articles = self.store.unseen(chat_id, candidates)[: self.settings.digest_size]
        if not articles:
            if query:
                await send_text(bot, chat_id, "没有找到符合时间范围的新闻，试试更短的关键词。")
            return False
        await self.deliver(bot, chat_id, articles, query=query, track=not bool(query))
        if self.news.last_failed_sources:
            await send_text(bot, chat_id, "部分新闻源暂时不可用，本次结果来自其余可用来源。")
        return True

    async def request_news(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not await self.authorize(update):
            return
        is_search = update.effective_message.text.startswith("/search")
        query = " ".join(context.args).strip() if is_search else ""
        if is_search and not query:
            await update.effective_message.reply_text("用法：/search 关键词，例如 /search 人工智能")
            return
        await self.handle_query(update, context, query)

    async def handle_query(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE, query: str
    ) -> None:
        if self.delivery_lock.locked():
            await update.effective_message.reply_text("正在整理上一份新闻，请稍后再试。")
            return
        async with self.delivery_lock:
            await update.effective_message.reply_text("正在查找新闻…")
            try:
                sent = await self.fetch_and_send(context.bot, update.effective_chat.id, query)
                if not sent and not query:
                    await update.effective_message.reply_text(
                        "暂时没有未推送的新新闻。可用 /search 主动搜索。"
                    )
            except NewsError:
                await update.effective_message.reply_text("新闻源暂时无法访问，请稍后重试。")

    async def message(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not await self.authorize(update):
            return
        message = update.effective_message
        try:
            if message.photo or message.voice or message.audio:
                if not self.ai.enabled:
                    await message.reply_text(
                        "请先在本机 .env 配置 OPENAI_API_KEY，以启用图片和语音理解。"
                    )
                    return
                if self.delivery_lock.locked():
                    await message.reply_text("正在整理新闻，请稍后再试。")
                    return
                media = message.photo[-1] if message.photo else (message.voice or message.audio)
                if not media.file_size or media.file_size > MAX_MEDIA_BYTES:
                    await message.reply_text("请发送不超过 19 MB 的图片或语音。")
                    return
                if getattr(media, "duration", 0) and media.duration > 180:
                    await message.reply_text("首版支持 3 分钟内的语音。")
                    return
                telegram_file = await media.get_file()
                data = bytes(await telegram_file.download_as_bytearray())
                if len(data) > MAX_MEDIA_BYTES:
                    await message.reply_text("文件过大，请压缩后重试。")
                    return
                if message.photo:
                    query = await self.ai.image_query(data, "image/jpeg", message.caption or "")
                    await message.reply_text(f"根据图片查找：{query}")
                else:
                    filename = (
                        "voice.ogg" if message.voice else (message.audio.file_name or "audio.mp3")
                    )
                    transcript = await self.ai.transcribe(data, filename)
                    await send_text(
                        context.bot, update.effective_chat.id, "语音识别：" + transcript
                    )
                    query = transcript
                    with contextlib.suppress(AIError):
                        query = await self.ai.text_query(transcript)
            elif message.text:
                query = message.text[:500]
                if self.ai.enabled:
                    with contextlib.suppress(AIError):
                        query = await self.ai.text_query(query)
            else:
                await message.reply_text("首版支持文字、图片和语音；视频理解尚未启用。")
                return
            if not query.strip():
                await message.reply_text("没有识别出可搜索的关键词，请再补充一点内容。")
                return
            await self.handle_query(update, context, query)
        except AIError as exc:
            await message.reply_text(str(exc))

    async def scheduled(self, context: ContextTypes.DEFAULT_TYPE) -> None:
        if self.store.get("paused") == "true" or self.delivery_lock.locked():
            return
        chat_id = self.store.get("chat_id")
        # Only the paired owner's private chat may receive scheduled pushes.
        if not chat_id or int(chat_id) != self.owner_id:
            return
        slot = due_slot(
            datetime.now(UTC), self.times, self.settings.timezone, self.settings.catchup_hours
        )
        if not slot or slot == self.store.get("last_slot") or time.monotonic() < self.next_retry:
            return
        async with self.delivery_lock:
            try:
                sent = await self.fetch_and_send(context.bot, int(chat_id))
                self.store.set("last_slot", slot)
                self.store.set("last_outcome", "已送达" if sent else "无新新闻")
                if sent:
                    self.store.set("last_delivery", datetime.now(UTC).isoformat())
                self.next_retry = 0
            except (NewsError, TelegramError):
                self.next_retry = time.monotonic() + 300
                self.store.set("last_outcome", "获取或投递失败，5 分钟后重试")
                log.warning("Scheduled edition failed; retry in five minutes")

    async def startup(self, application: Application) -> None:
        await application.bot.set_my_commands(
            [
                BotCommand(command, description)
                for command, description in [
                    ("news", "获取最新新闻"),
                    ("search", "搜索新闻"),
                    ("topics", "订阅主题"),
                    ("schedule", "推送时间"),
                    ("voice", "语音播报开关"),
                    ("status", "运行状态"),
                    ("pause", "暂停推送"),
                    ("resume", "恢复推送"),
                    ("help", "帮助"),
                ]
            ]
        )
        log.info("NewsPaw started; private-chat polling enabled")

    async def shutdown(self, application: Application) -> None:
        await self.news.close()
        await self.ai.close()
        self.store.close()

    async def error(self, update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
        # Telegram request URLs include the bot token; never log exception reprs.
        log.error("Handler failed (%s)", type(context.error).__name__)
        if (
            isinstance(update, Update)
            and update.effective_message
            and update.effective_user
            and update.effective_user.id == self.owner_id
        ):
            with contextlib.suppress(TelegramError):
                await update.effective_message.reply_text("请求暂时失败，请稍后重试。")

    def application(self) -> Application:
        application = (
            Application.builder()
            .token(self.settings.telegram_token)
            .rate_limiter(AIORateLimiter(overall_max_rate=1, overall_time_period=1, max_retries=2))
            .concurrent_updates(False)
            .post_init(self.startup)
            .post_shutdown(self.shutdown)
            .build()
        )
        application.add_handler(CommandHandler("pair", self.pair))
        application.add_handler(CommandHandler(["start", "help"], self.start))
        application.add_handler(CommandHandler("status", self.status))
        application.add_handler(CommandHandler(["news", "search"], self.request_news))
        application.add_handler(
            CommandHandler(["topics", "schedule", "voice", "pause", "resume"], self.configure)
        )
        application.add_handler(MessageHandler(~filters.COMMAND, self.message))
        application.add_error_handler(self.error)
        application.job_queue.run_repeating(
            self.scheduled,
            interval=30,
            first=3,
            job_kwargs={"max_instances": 1, "coalesce": True, "misfire_grace_time": 60},
        )
        return application
