# 独立终审范围

设计作者：Codex。审阅者：用户明确指定的 Kimi K3.1 Pro。此次是 NewsPaw 产品需求/架构/backlog 审计，不是代码发布审查，也不授权开始实现、修改文件、创建 issue 或发送消息。

请只读审阅以下完整目标：

1. `docs/planning/requirements.md`：已确认需求和边界决策。
2. `docs/planning/audit-2026-11-07.md`：原型差距与证据。
3. `docs/planning/backlog.json`：9 epics / 33 child issues 的具体范围、依赖和验收。
4. `docs/planning/README.md`、`afk-handoff.md`、`github-map.json`：阶段顺序与真实 GitHub 映射。
5. `docs/system-design.md`、`model-routing.md`、`telegram-routing.md`、`delivery-formats.md`、`source-strategy.md`：原需求详情。
6. `docs/mockup/README.md` 和既有 mockup 的相关界面文字/结构；无需读取内嵌 base64 图像，只检查需求是否保持，不要求重设计。
7. 必要时阅读 `src/newspaw/` 和 `tests/` 验证审计说法。禁止读取 `.env`、运行数据库、用户凭据、私有名单或执行真实采集/发送/服务安装。

重点找：遗漏需求、错误前提、依赖环/无法执行的任务、粒度过大导致 AFK 不可验收、普通/成人泄漏、配置修改与在途发送冲突、X 翻页/预算/成员分类、来源新鲜度与故障混淆、媒体能力与费用、安装和迁移边界。每项需具体引用并说明会产生什么错误结果；不因文风偏好新增工作。

已完成内部审计：133 个已有测试与 ruff 通过；backlog 依赖 DAG 已检查。内部发现 A01–A16 已映射到未实施 issues，不能把“现有原型缺少目标功能”再次当成拆分设计缺陷；需判断任务是否真的覆盖修复。若文档规则有冲突，以 requirements.md 补充后的行为为审阅目标，但应报告仍可能误导开发者的实质冲突。

请明确给出 SOUND / SOUND WITH CONCERNS / RETHINK。对每个 finding 标明 P1/P2/minor、文件位置、需求锚点、可达触发、错误后果和最小修正。这是设计审阅，不要求现在实现未来功能或真实付费联调。输出中文。
