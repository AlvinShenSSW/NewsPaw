# 重构 mockup（macOS 窗口样式 · 2026-11-10）

Epic E10 的界面基线。六个静态 HTML 各自是一个 macOS 窗口（1180×N 或 760×580），直接用浏览器打开即可，窗口之间的侧栏与按钮链接可点击；同一套画板也发布在 [Design 画布](https://claude.ai/artifact/PqJ1KV8JtV1C7LXNyGW4Pt)。逐控件的状态与文案见[交互规格](../../planning/ux-redesign/interaction-spec.md)。

| 文件 | 画板 | 对应 issue | 替代的现状 |
|---|---|---|---|
| [setup.html](setup.html) · [png](setup.png) | 0 首次设置窗口（三步） | [R07 #85](https://github.com/AlvinShenSSW/NewsPaw/issues/85) | 跨 4 页 / 9 个 sheet / 35 次点击 |
| [overview.html](overview.html) · [png](overview.png) | 1 概览（新首页） | [R08 #86](https://github.com/AlvinShenSSW/NewsPaw/issues/86) | 未连接时的订阅页死胡同 |
| [digests.html](digests.html) · [png](digests.png) | 2 简报（内联展开编辑） | [R09 #87](https://github.com/AlvinShenSSW/NewsPaw/issues/87) | 分类卡 + 来源区 + 订阅 sheet + 源 sheet |
| [connect.html](connect.html) · [png](connect.png) | 3 接入（机器人 / 模型 / 费用） | [R10 #88](https://github.com/AlvinShenSSW/NewsPaw/issues/88) | 模型页 + 推送页 + 运行策略 sheet |
| [x-accounts.html](x-accounts.html) · [png](x-accounts.png) | 4 X 账号 | [R11 #89](https://github.com/AlvinShenSSW/NewsPaw/issues/89) | 856 行 XWorkspace、4 个 sheet |
| [settings.html](settings.html) · [png](settings.png) | 5 设置 | [R12 #90](https://github.com/AlvinShenSSW/NewsPaw/issues/90) | 语言页 + 推送页运维区 + 诊断 sheet |

## 视觉约定（来自 macOS Settings，不是网页）

- 侧栏 200pt，`.sidebar` 列表，选中行系统蓝填充白字；图标为 20×20 彩色圆角方块内白色 SF Symbol。
- 工具栏 52pt：左页面标题 15pt bold，右主操作。
- 内容区 `Form(.grouped)`：白色分组、1px 边框、8pt 圆角，行高 ≥ 40pt，13pt 正文 + 11pt 次要文字。
- 控件：`Toggle(.switch)` 38×22、`Picker(.menu)` 带蓝色双箭头、`Picker(.segmented)`、`DatePicker(.stepperField)`、`Slider`、`DisclosureGroup`。
- 状态用「8pt 色点 + 文字」，不用网页式胶囊徽章；仅「成人」用紫色小标签。
- Logo 与分类图标沿用 `assets/branding/`。

截图由 headless Chrome 渲染（浅色）；实现后把真实 App 的三语浅/深色截图放到 `actual/`。

HTML 里的字母头像、示例账号、金额、时间均为示意数据，不是真实配置。
