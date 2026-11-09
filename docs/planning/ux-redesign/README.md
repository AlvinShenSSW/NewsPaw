# 交互重构（Epic E10）

2026-11-10 · 用户决定：对 Codex 实现的设置 App 做交互重构。前提是**单人私用、一台 Mac、一个后台、推送到自己的 Telegram 机器人**；目标是简单好用、符合人的使用逻辑、不过度工程。

- [审计 2026-11-09](audit-2026-11-09.md)：架构 / 代码 / 产品功能 / 交互四路审计与根因。
- [交互规格](interaction-spec.md)：词表、macOS 组件映射、六个界面逐控件的状态与文案、数据依赖、端到端验收。
- [重构 mockup](../../mockup/redesign/README.md)：macOS 窗口样式的静态 HTML 与截图（新界面基线）。
- Design 画布（可点击跳转）：https://claude.ai/artifact/PqJ1KV8JtV1C7LXNyGW4Pt

## 已决定的事（2026-11-10）

| 决定 | 结果 |
|---|---|
| category / subscription / scope / route / target | 合并为一个「简报」对象，schema v3 → v4；拆分为显式动作 |
| Key 保存时自动做一次文字探测（约 $0.001） | 接受；spec 19「保存零网络」条款由 R01 改写 |
| 价格未知 | 照常执行并标注「未计价」，不再阻塞 |
| 旧 `.env` 栈（bot.py / config.py / schedule.py / service.py / grok.py / ai.py） | 删除，git 历史保留 |
| 界面基线 | 改为 docs/mockup/redesign；原五页 mockup 归档不再作为验收依据 |

保留不动：普通/成人隔离与禁止跨组回退、outcome_unknown 不自动重试、投递回执防重发、一次性配对码与仅主人私聊、Keychain 只存引用、源文本不可信、迁移前备份。

## GitHub

| Epic | 子任务 |
|---|---|
| [E10 · 交互重构 #78](https://github.com/AlvinShenSSW/NewsPaw/issues/78) | 契约 [R01 #79](https://github.com/AlvinShenSSW/NewsPaw/issues/79) · 后端 [R02 #80](https://github.com/AlvinShenSSW/NewsPaw/issues/80) [R03 #81](https://github.com/AlvinShenSSW/NewsPaw/issues/81) [R04 #82](https://github.com/AlvinShenSSW/NewsPaw/issues/82) [R05 #83](https://github.com/AlvinShenSSW/NewsPaw/issues/83) · Swift [R06 #84](https://github.com/AlvinShenSSW/NewsPaw/issues/84) [R07 #85](https://github.com/AlvinShenSSW/NewsPaw/issues/85) [R08 #86](https://github.com/AlvinShenSSW/NewsPaw/issues/86) [R09 #87](https://github.com/AlvinShenSSW/NewsPaw/issues/87) [R10 #88](https://github.com/AlvinShenSSW/NewsPaw/issues/88) [R11 #89](https://github.com/AlvinShenSSW/NewsPaw/issues/89) [R12 #90](https://github.com/AlvinShenSSW/NewsPaw/issues/90) · 清理 [R13 #91](https://github.com/AlvinShenSSW/NewsPaw/issues/91) · 测试 [R14 #92](https://github.com/AlvinShenSSW/NewsPaw/issues/92) |

依赖顺序：R01 冻结 → R02 / R03 / R04（后端）→ R06（外壳）→ R07 / R08 / R09（P0 页面）→ R05、R10 / R11 / R12（P1）。R13、R14 可随时并行；R14 修的是当前 `pytest` 33 个失败（测试时钟写死 2026-11-08），建议最先做。

沿用 AFK 流程：只执行用户明确交付的 issue；Codex 主导，Kimi K3.1 Pro 唯一外门；默认 leave-open。
