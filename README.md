# NewsPaw

个人 Mac 上的新闻管家：菜单栏配置、分主题简报、X 账号聚合和 Telegram 交互。

**目前为系统设计和后台原型，尚不是可安装的完整 Mac 应用。未启用后台服务或真实推送。**

- [产品与系统设计](docs/system-design.md)：八类主题、每类独立时间、X 账号单独日更与费用控制、原生 Mac 界面、模型路由、实施顺序。
- [新闻来源与添加流程](docs/source-strategy.md)：中国与 AI 新分类、推荐和自选来源、RSS/API/网页采集、App 内添加与路由预览。
- [主备模型与语言设置](docs/model-routing.md)：每个槽位独立 URL/Key/模型、分类覆盖、失败切换、界面与新闻输出的独立三语设置。
- [推送样式与 AI 报纸](docs/delivery-formats.md)：默认文字链接、按需来源配图、指定内容生成为 1–2 张报纸图，附可点击来源。
- [多 Bot 绑定与新闻分配](docs/telegram-routing.md)：分别绑定多个 Telegram Bot，按分类和特别关注账号选择一个或多个接收目标。
- [后台原型与证据规则](docs/architecture.md)：已经实现的模块和仍待集成的边界。

目标模型路由：普通新闻和普通 X 使用 GPT-6 Luna 主用、MiMo Flash 备用；AV 产业与 X 成人博主分别订阅，默认继承 DeepSeek Flash 主用、Grok 4.3 备用的成人模型组。每个分类可覆盖本组的主备 URL、Key 与模型。两类 X 分区都支持特别关注账号的独立日更，分区读取上限受同一个 X 总预算约束。App 显示语言与所有简报的输出语言分别选择简体中文、English 或日本語。新闻来源、时间校验和投递记录由 NewsPaw 管理。

## 本地开发

需要 Python 3.12+、[uv](https://docs.astral.sh/uv/)；语音处理另需 ffmpeg，本机语音播报使用 macOS `say`。

```sh
uv sync
uv run pytest -q
uv run ruff check .
uv run newspaw --help
```

开发原型提供不依赖模型或 Telegram 凭据的采集诊断：

```sh
uv run newspaw search '人工智能' --limit 3
uv run newspaw collect --json
uv run newspaw audit --json
```

这些命令只采集并保存证据，不发送消息。出版商来源配置在 `sources.toml`，无映射主题的发现方式明确记录为 Google News RSS；不是调用某个网页搜索 API。缺失、无时区、过期或未来的发布时间不会混入新鲜新闻。

## 可选的 Telegram 原型

```sh
uv run newspaw init
# 编辑本机 .env，填写 Telegram token 和需要的模型 API key。
uv run newspaw doctor
uv run newspaw run
```

在 bot 私聊发送 `/pair <本机 .env 中的 PAIRING_CODE>` 配对唯一主人；或先填写 `TELEGRAM_OWNER_ID`。凭据不要提交到 GitHub。首次配对前不向任何聊天推送。

当前 bot 支持 `/news`、`/search`、`/topics`、`/schedule`、`/voice on|off`、`/pause`、`/resume` 和 `/status`，以及普通新闻的文字、图片和语音请求。**它目前仍采用单 Bot 和全局推送时间；目标的多 Bot 分类分配、分主题时间、X 日更、AV 模型路由、完整投递队列与 AI 报纸尚未接入 bot。** 独立采集/模型适配模块的存在不代表这些产品功能已经完成。

开发者可使用 `newspaw service install|start|stop|status|uninstall` 管理原型 LaunchAgent。`install` 会实际启动服务；配置正确并完成前台验证后再使用。正式版本将改用原生设置界面、Keychain 与应用内的后台服务管理。

常驻仅在用户登录、Mac 唤醒且联网时能够工作。网络超时的发送结果可能不确定，不能保证严格恰好一次投递。模型和 Telegram 联调需要真实凭据；当前自动测试使用模拟接口，不代表线上账户已验证。

## 数据与隐私

`.env`、`data/`、运行数据库、日志与虚拟环境不进入版本控制。证据记录保留最近 200 次采集；发送回执独立保存。原始媒体只用于请求处理，不保存为长期素材。

普通摘要只基于提供的标题与摘录，不声称读完全文或完成独立事实核查。AV 适配器限制为非露骨产业信息，处理失败时不跨服务自动回退，也不回传原始推广文案。
