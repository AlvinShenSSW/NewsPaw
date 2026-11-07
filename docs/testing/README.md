# 验证与发布记录

一个人、一台 Mac、一个后台服务多个 Bot。验证服务于实际功能，不搭建额外测试平台。

## 当前自动检查

本机和 GitHub Actions 使用 `uv sync --locked`、`uv run ruff check .`、`uv run pytest -q`、`uv build`。CI 在 Linux/macOS 跑 Python 3.12，所有步骤失败都会使 job 失败；Draft 与 Ready 都运行检查。Actions 只有仓库只读权限，不提供凭据，也没有发布/部署步骤。依赖安装需要网络；产品测试本身不访问网络。

`tests/conftest.py` 在测试期间阻止 Python Internet socket 连接/UDP 发送/DNS，保留 Unix socket；清除继承的供应商与 Telegram 凭据，切到临时工作目录，禁用隐式 dotenv 文件发现。显式临时配置文件仍可解析。HTTP 与模型测试使用 fake transport。此 fixture 不是恶意代码或子进程沙箱，测试收集阶段不得联网，子进程边界仍须显式 mock。

Swift 工程尚未建立，当前没有 Swift 构建通过记录。U01 添加工程时须增加 macOS `swift build` / `swift test` 等实际命令；UI 与打包检查由 U01/O02 补齐。业务模块自己的故障注入随对应 issue 提交。现有原型测试通过不代表以下产品目标通过。

## 发布验收清单

以下全部 **待实现/待验收**；每项完成后记录实际命令、revision、环境和结果。禁止以 mockup、模块存在或模拟 API 冒充真实接入。

| 阶段 | 行为与失败路径 | 负责 issue |
| --- | --- | --- |
| M1 | 两 Bot 同一 owner 配对、分类独立时间/目标，拒绝非 owner 命令 | T01–03、Q01–03 |
| M1 | UI/新闻语言独立三语；配置持久化、升级回滚与旧闻不重放 | F01/F04、M04、U01–03 |
| M1 | 主备同分区；付费响应丢失/崩溃无自动二次调用；预算预留不丢失 | M01–03、Q01 |
| M1 | 睡眠/断网/部分发送/未知回执恢复；源失败与零新闻区分 | S01/S02、Q01–03 |
| M1 | 添加源、安装启动/停止/升级/卸载、诊断导出不含秘密 | S04、O01/O02 |
| M2 | X 增量分页、用户名变化、List 新成员分类、预算限额、特别账号日更 | X01–03、U04 |
| M2 | AV 独立采集；成人原文/媒体/上下文不进入普通提供商或未授权 Bot | S05、F02、M02、T02 |
| M2 | AI 模型/Skill/repo 证据与推荐边界 | S03 |
| M2 | 默认文字、来源图片、真实一到两页生图报纸、三语可读与引用一致 | D01/D02 |
| M2 | 图片/语音交互与能力不足时的明确状态 | D03 |
| Later | 显式启用的重大提醒/视频理解；默认关闭 | X04 |

M1/M2 发布必须检查对应依赖全集、每项内部/Kimi审阅及最终提交的本机和远端检查。未通过项目仍保留待验收，不能宣称产品完成。

## 本机真实接入验收

真实 Key、Bot Token、账号名单只在本机 Keychain/私有配置中填写，不进入 CI 或 fixture。接入测试在对应功能实现后由操作人显式启用：先确认目标 Bot/chat、输入源、预算与预期副作用，再做少量真实读取/模型调用/消息投递并记录脱敏结果。CI 不提供自动启用开关，也不读取这些凭据。签名、公证和真实服务安装由 O02 单独验证。

## 工作流依据

官方 [checkout](https://github.com/actions/checkout)、[setup-python](https://github.com/actions/setup-python)、[setup-uv](https://github.com/astral-sh/setup-uv) 的 release/tag 已在建工作流时核对，固定对应提交。之后升级需通过同样检查，不静默引用浮动主分支。
