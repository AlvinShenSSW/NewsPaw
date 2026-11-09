# R09 — 简报页（#87）

冻结契约：issue #87 验收项 + `docs/planning/ux-redesign/interaction-spec.md` §5。依赖 R03（简报即订阅、v4 字段）与 R06（`BackendClient`、`EditorState`、`Words`、`FailureNote`）。

## 实现

- `Digests.swift` 替换旧 `DigestsPage`（分类卡片 + sheet）、`SubscriptionEditor`、`SourceWorkspace`；`SubscriptionCopy` 仍被其他旧视图使用，移到单独文件，随 R10–R12 删除。
- 每份订阅一行（按目录顺序）：图标、名称（+ 成人标签）、摘要（时间 → 机器人 · 来源数 · 下一期）、今天这期的 §4.3 状态、开关、编辑。同页只展开一行。
- 所有字段改动都经 `DigestsData.save` → `EditorState`：读取最新订阅草稿，套用改动，`subscriptions.save`（保持原开关，除非显式开/关），冲突时重读重放一次。失败在行内显示错误码文案；`subscription_not_ready` 时同时列出 `subscriptions.preview` 的阻塞项。时间用 1 秒防抖保存。
- 开启（§5.2）：没有来源时从推荐目录把可读的源加为待验证草稿（`enabled:false`、该分类、分区、范围），逐个 `sources.preview`，成功的才启用；未选机器人且只有一个可用机器人时自动选它；然后 `subscriptions.save(enable:true)`，成功后展开该行。缺机器人、成人缺 Key 或缺允许成人的机器人时开关禁用，并给出「去接入补齐」。
- 关闭：确认对话框；今天还有待发的一期时写出时间。
- 来源子表（§5.4）：跟随分类的简报，复选框开关来源本身；有自己来源列表的简报（拆分后），复选框只增删它的 `source_ids`，不影响别的简报。待验证的源复选框禁用，按钮「试采集后启用」；试采集结果 5 秒后收起。移除前用 `sources.impact` 列出会因此关闭的简报。
- 拆分（§5.7）：一次 `config.save`：副本取娱乐范围的源，原简报保留其余，两者都改为自有列表；副本先关闭并展开。只有一边有源时两者都继续跟随分类。并回：删除副本，剩下的一份恢复跟随分类。
- 立即试发一期（§5.6）：先 `subscriptions.preview`，Popover 显示来源数、最多条数、机器人或阻塞项，确认后 `subscriptions.send_now`；成功后行内「已发送 · 查看」跳到概览。

## 依据仓库证据修正契约

- 后台没有「成人专用机器人」概念（`adult_allowed` 只表示可以收成人内容，普通简报可发到任何已配对机器人），所以普通简报不对机器人灰显；成人简报对不允许成人的机器人灰显。
- `sources.import_opml` 导入的源没有分类（`partition:null`、`category_ids:[]`），不会出现在任何简报里。导入结果 sheet 让用户选一个普通简报，把新源归入该分类为待验证草稿，再在该简报里试采集启用。
- `subscriptions.preview` 不返回预计条数和费用，Popover 显示「从 N 个来源选最多 M 条，发到 @bot」。
- 「AI 报纸」只在 `newspaper.policy` 已开启且有生图模型时可选，否则给出去接入页的提示。

## 验证

`swift test`：`DigestsTests` 用内存后台覆盖开启流程（推荐源草稿、试采集失败保持关闭、唯一机器人自动选中）、后台并发改动后合并保存、拒绝保存时行内显示阻塞项、拆分/并回、自有列表增删来源、成人前置、时间去重排序、下一期计算、三语文案。离屏截图对照隔离后台。
