import Foundation
import SwiftUI

enum SubscriptionCopy {
    case edit, new, name, zone, times, count, inherit, explicit, style, sourceList, botList
    case dismiss, inheritStyle, textStyle, imageStyle, newspaperStyle
    case weighted, domestic, entertainment, preview, draft, activate, route, ready, needsReview
    case missingTime, missingSource, missingBot, missingModel, previewSource
    case catalog, sourceURL, discover, saveSource, trial, accepted, pause, remove, impact
    case newSource, sourceType, xDestination, previewPassed, previewUnavailable
    case current, stale, unknownFreshness, partialCoverage
    case none, importOPML, duplicate, added, rejected, neutral, unsupported, enableSource
    case pauseCategory, pauseCategoryImpact, chooseSubscription, categoryPauseFailed

    func text(_ language: AppLanguage) -> String {
        let words: (String, String, String) = switch self {
        case .edit: ("编辑订阅", "Edit subscription", "購読を編集")
        case .new: ("新增订阅", "New subscription", "新しい購読")
        case .name: ("名称", "Name", "名前")
        case .zone: ("时区", "Time zone", "タイムゾーン")
        case .times: ("时间（HH:MM，逗号分隔）", "Times (HH:MM, comma separated)", "時刻（HH:MM、カンマ区切り）")
        case .count: ("每期条数上限", "Maximum items per edition", "1 号あたりの上限")
        case .inherit: ("使用分类来源", "Use category sources", "カテゴリの情報源を使う")
        case .explicit: ("仅使用勾选的来源", "Use only selected sources", "選択した情報源のみ")
        case .style: ("推送样式", "Delivery style", "配信形式")
        case .sourceList: ("来源", "Sources", "情報源")
        case .botList: ("推送 Bot", "Delivery Bots", "配信先 Bot")
        case .dismiss: ("取消", "Cancel", "キャンセル")
        case .inheritStyle: ("继承样式", "Inherit style", "既定の形式を使用")
        case .textStyle: ("文字和链接", "Text and links", "テキストとリンク")
        case .imageStyle: ("来源配图", "Source image", "情報源の画像")
        case .newspaperStyle: ("AI 报纸图", "AI newspaper", "AI 新聞画像")
        case .weighted: ("调整国内与娱乐的权重", "Weight domestic and entertainment coverage", "国内とエンタメの重みを調整")
        case .domestic: ("国内", "Domestic", "国内")
        case .entertainment: ("娱乐", "Entertainment", "エンタメ")
        case .preview: ("查看生效路由", "Preview effective route", "配信経路を確認")
        case .draft: ("保存为停用草稿", "Save inactive draft", "無効の下書きを保存")
        case .activate: ("保存并启用", "Save and enable", "保存して有効にする")
        case .route: ("生效路由", "Effective route", "配信経路")
        case .ready: ("可启用", "Ready to enable", "有効化できます")
        case .needsReview: ("配置待检查", "Configuration needs review", "設定を確認してください")
        case .missingTime: ("还没有推送时间", "No delivery time is set", "配信時刻が未設定です")
        case .missingSource: ("缺少可用来源", "No eligible sources", "利用可能な情報源がありません")
        case .missingBot: ("缺少已配对的推送 Bot", "A paired delivery Bot is needed", "ペアリング済みの Bot が必要です")
        case .missingModel: ("模型槽缺少凭据或能力验证", "Model credentials or verification are missing", "モデルの認証情報または検証が必要です")
        case .previewSource: ("来源需先通过试采集", "Sources need a collection preview", "情報源の試験取得が必要です")
        case .newSource: ("添加来源", "Add source", "情報源を追加")
        case .sourceType: ("来源类型", "Source type", "情報源の種類")
        case .xDestination: ("请在 X 账号页添加", "Add this on the X Accounts page", "X アカウント画面で追加してください")
        case .previewPassed: ("实际试采集通过", "Collection preview passed", "試験取得に成功しました")
        case .previewUnavailable: ("尚未通过试采集", "Collection preview has not passed", "試験取得は未確認です")
        case .current: ("当前有符合时间窗的新闻", "Current items in the time window", "対象期間内の記事があります")
        case .stale: ("时间窗内没有可用新闻", "No current items in the time window", "対象期間内の記事はありません")
        case .unknownFreshness: ("新鲜度未知", "Freshness unknown", "鮮度不明")
        case .partialCoverage: ("采集覆盖不完整", "Collection coverage is partial", "取得範囲は一部です")
        case .catalog: ("来源目录", "Source catalog", "情報源カタログ")
        case .sourceURL: ("来源网址", "Source URL", "情報源 URL")
        case .discover: ("识别来源", "Identify source", "情報源を識別")
        case .saveSource: ("保存停用来源", "Save inactive source", "無効の情報源を保存")
        case .trial: ("试采集", "Preview collection", "試験取得")
        case .accepted: ("符合条件的条数", "Eligible items", "対象記事数")
        case .pause: ("暂停来源", "Pause source", "情報源を一時停止")
        case .remove: ("删除来源", "Remove source", "情報源を削除")
        case .impact: ("受影响的订阅", "Affected subscriptions", "影響を受ける購読")
        case .none: ("无", "None", "なし")
        case .importOPML: ("导入 OPML", "Import OPML", "OPML を読み込む")
        case .duplicate: ("重复", "Duplicates", "重複")
        case .added: ("新增草稿", "Drafts added", "追加した下書き")
        case .rejected: ("未导入", "Rejected", "読み込み不可")
        case .neutral: ("未分类", "Unclassified", "未分類")
        case .unsupported: ("需要适配，已保留为草稿", "Adapter needed. Saved as a draft.", "アダプターが必要です。下書きとして保存しました")
        case .enableSource: ("启用已验证来源", "Enable verified source", "検証済みの情報源を有効にする")
        case .pauseCategory: ("暂停此分类", "Pause this category", "このカテゴリを一時停止")
        case .pauseCategoryImpact: ("该分类中启用的订阅将暂停，配置会保留。", "Active subscriptions in this category will pause. Their settings are kept.", "このカテゴリの有効な購読を一時停止します。設定は保持されます。")
        case .chooseSubscription: ("选择要启用的订阅", "Choose a subscription to activate", "有効にする購読を選択")
        case .categoryPauseFailed: ("未能暂停此分类", "Could not pause this category", "このカテゴリを一時停止できませんでした")
        }
        return switch language {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}
