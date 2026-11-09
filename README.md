# NewsPaw

个人 Mac 上的新闻管家：菜单栏配置、分主题简报、X 账号聚合和 Telegram 交互。

**目前为系统设计和后台原型，尚不是可安装的完整 Mac 应用。未启用后台服务或真实推送。**

- [开发路线图与 GitHub epics/issues](docs/planning/README.md)：全盘审计、需求验收、任务依赖与 Kimi 独立终审状态。
- [已确认的界面基线](docs/mockup/README.md)：后续沿用当前 mockup，不重新设计。

- [产品与系统设计](docs/system-design.md)：八类主题、每类独立时间、X 账号单独日更与费用控制、原生 Mac 界面、模型路由、实施顺序。
- [新闻来源与添加流程](docs/source-strategy.md)：中国与 AI 新分类、推荐和自选来源、RSS/API/网页采集、App 内添加与路由预览。
- [主备模型与语言设置](docs/model-routing.md)：每个槽位独立 URL/Key/模型、分类覆盖、失败切换、界面与新闻输出的独立三语设置。
- [推送样式与 AI 报纸](docs/delivery-formats.md)：默认文字链接、按需来源配图、指定内容生成为 1–2 张报纸图，附可点击来源。
- [多 Bot 绑定与新闻分配](docs/telegram-routing.md)：分别绑定多个 Telegram Bot，按分类和特别关注账号选择一个或多个接收目标。
- [后台原型与证据规则](docs/architecture.md)：已经实现的模块和仍待集成的边界。

目标模型路由：普通新闻和普通 X 使用 GPT-6 Luna 主用、MiMo Flash 备用；AV 产业与 X 成人博主分别订阅，默认继承 DeepSeek Flash 主用、Grok 4.3 备用的成人模型组。每个分类可覆盖本组的主备 URL、Key 与模型。两类 X 分区都支持特别关注账号的独立日更，分区读取上限受同一个 X 总预算约束。App 显示语言与所有简报的输出语言分别选择简体中文、English 或日本語。新闻来源、时间校验和投递记录由 NewsPaw 管理。

## 本地开发

需要 Python 3.12+、[uv](https://docs.astral.sh/uv/)；原生界面需要 Swift 工具链。语音与视频处理另需 ffmpeg。

```sh
uv sync
uv run pytest -q
uv run ruff check .
swift test --package-path macos/NewsPaw
uv run newspaw --help
```

后台只有一个入口：`newspaw control --data-dir <私有数据目录>`。它运行本机后台与仅限当前用户的 Unix socket 配置接口；Mac App 的登录项（`NewsPawResident`）以 `python -m newspaw control` 启动它，默认数据目录为 `~/Library/Application Support/NewsPaw`。配置、来源、模型、Bot 与调度都通过原生设置界面写入后台，凭据存放在 macOS Keychain。打包与安装见 [packaging/README.md](packaging/README.md)。

早期基于 `.env` 的单 Bot 原型（`newspaw init / doctor / run / service / search / collect / audit`、`/pair` 配对和全局推送时间）已经删除。仍保留一次性的显式导入：后台的 `legacy.preferences` 与 `legacy.secrets` 操作读取用户指定的旧 `.env` 文件（以及旧数据库中旧 bot 保存的主题与时间），把非秘密偏好导入为默认关闭的订阅，把 Telegram Token 与模型 Key 写入 Keychain；不删除旧 `.env`，也不自动启用订阅或推送。原生界面尚未提供这一入口。

如果曾用旧原型的 `newspaw service install` 安装过 LaunchAgent（`io.newspaw.agent`），请在更新代码前用旧版本执行 `newspaw service uninstall`，或手动执行 `launchctl bootout gui/$(id -u)/io.newspaw.agent` 并删除 `~/Library/LaunchAgents/io.newspaw.agent.plist`。新版本不再提供该命令，旧 LaunchAgent 若继续运行只会反复启动失败；App 在它仍被加载时也会拒绝注册新的登录项。

常驻仅在用户登录、Mac 唤醒且联网时能够工作。网络超时的发送结果可能不确定，不能保证严格恰好一次投递。模型和 Telegram 联调需要真实凭据；当前自动测试使用模拟接口，不代表线上账户已验证。

## 数据与隐私

`.env`、`data/`、运行数据库、日志与虚拟环境不进入版本控制。数据库、日志与媒体目录使用本机私有权限。采集证据、生成的媒体与日志由后台的清理操作按各自边界清理，仍被待发任务引用的证据不会被删除；投递回执独立保存。原始媒体只用于请求处理，不保存为长期素材。

普通摘要只基于提供的标题与摘录，不声称读完全文或完成独立事实核查。AV 产业内容只走专用适配器和成人模型组，处理失败时不跨组回退，也不回传原始推广文案。
