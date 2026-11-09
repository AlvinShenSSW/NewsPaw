import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case zhHans = "zh-Hans"
    case en
    case ja

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: "简体中文"
        case .en: "English"
        case .ja: "日本語"
        }
    }

    func text(_ key: Phrase) -> String {
        let words = key.words
        return switch self {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}

/// The five sidebar pages (interaction-spec §1.1).
enum Page: String, CaseIterable, Identifiable {
    case overview, digests, xAccounts, connect, settings

    var id: String { rawValue }

    var title: Words {
        switch self {
        case .overview: L10n.Page.overview
        case .digests: L10n.Page.digests
        case .xAccounts: L10n.Page.xAccounts
        case .connect: L10n.Page.connect
        case .settings: L10n.Page.settings
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house.fill"
        case .digests: "newspaper.fill"
        case .xAccounts: "xmark"
        case .connect: "link"
        case .settings: "gearshape.fill"
        }
    }
}

enum Phrase {
    case settings, tagline, subscriptions, accounts, models, delivery
    case subscriptionsNote, accountsNote, modelsNote, deliveryNote, languageNote
    case connected, connecting, offline, stopping, incompatible, refresh, openSettings
    case quitSettings, stopBackend, lifecycleNote, offlineNote, unavailable, noSources, noAccounts, noBots
    case displayLocal, saveFailed, conflict, stopFailed
    case categories, sources, ordinary, adult, unclassified, special, enabled, disabled
    case primary, backup, verified, unverified, unpaired, paused, paired, modelSlots
    case world, japan, australia, china, electronics, ai, av, x, xAdult

    var words: (String, String, String) {
        switch self {
        case .settings: ("设置", "Settings", "設定")
        case .tagline: ("你的新闻伙伴", "Your news companion", "ニュースの相棒")
        case .subscriptions: ("订阅与来源", "Subscriptions & Sources", "購読と情報源")
        case .accounts: ("X 账号", "X Accounts", "X アカウント")
        case .models: ("模型", "Models", "モデル")
        case .delivery: ("推送与运行", "Delivery & Service", "配信と実行")
        case .subscriptionsNote: ("查看订阅的分类和配置的新闻源。", "View your subscriptions and configured news sources.", "購読中の分類と設定済みの情報源を確認できます。")
        case .accountsNote: ("普通与成人账号分开；特别关注账号单独汇总。", "Ordinary and adult accounts stay separate. Special accounts have their own digest.", "通常と成人向けを分け、特別フォローは個別にまとめます。")
        case .modelsNote: ("每个内容分区都有自己的主用和备用模型。", "Each content group has its own primary and backup models.", "各コンテンツ区分に主モデルと予備モデルがあります。")
        case .deliveryNote: ("查看各 Telegram Bot 的实际绑定状态和本机后台。", "See each Telegram bot's binding and the local service.", "Telegram Bot ごとの連携状態とローカルサービスを確認します。")
        case .languageNote: ("界面语言与新闻输出语言可以不同。", "Choose the display and news languages separately.", "表示言語とニュースの出力言語は別々に設定できます。")
        case .connected: ("后台已连接", "Backend connected", "バックエンドに接続済み")
        case .connecting: ("正在连接后台", "Connecting to backend", "バックエンドに接続中")
        case .offline: ("后台未连接", "Backend disconnected", "バックエンド未接続")
        case .stopping: ("后台正在停止", "Backend stopping", "バックエンドを停止中")
        case .incompatible: ("后台版本不兼容", "Incompatible backend", "バックエンドのバージョンが非対応")
        case .refresh: ("刷新状态", "Refresh Status", "状態を更新")
        case .openSettings: ("打开 NewsPaw 设置", "Open NewsPaw Settings", "NewsPaw 設定を開く")
        case .quitSettings: ("退出设置", "Quit Settings", "設定を終了")
        case .stopBackend: ("停止后台", "Stop Backend", "バックエンドを停止")
        case .lifecycleNote: ("关闭窗口或退出设置，后台仍可继续运行。", "Closing the window or quitting Settings leaves the backend running.", "ウインドウを閉じても、設定を終了しても、バックエンドは動作を続けます。")
        case .offlineNote: ("启动本机 NewsPaw 后台后刷新状态。", "Start the local NewsPaw backend, then refresh.", "ローカルの NewsPaw バックエンドを起動してから更新してください。")
        case .unavailable: ("暂不可用", "Unavailable", "利用できません")
        case .noSources: ("尚未配置新闻源", "No sources configured", "情報源は未設定です")
        case .noAccounts: ("尚未配置 X 账号", "No X accounts configured", "X アカウントは未設定です")
        case .noBots: ("尚未配置 Telegram Bot", "No Telegram bots configured", "Telegram Bot は未設定です")
        case .displayLocal: ("界面语言保存在这台 Mac。", "Display language is saved on this Mac.", "表示言語はこの Mac に保存されます。")
        case .saveFailed: ("没有保存成功，请再试一次。", "That was not saved. Try again.", "保存できませんでした。もう一度お試しください。")
        case .conflict: ("保存时配置已被更改。", "Settings changed while saving.", "保存中に設定が変更されました。")
        case .stopFailed: ("未能确认后台已停止", "Could not confirm that the backend stopped", "バックエンドの停止を確認できませんでした")
        case .categories: ("新闻分类", "News categories", "ニュース分類")
        case .sources: ("来源管理", "News sources", "情報源")
        case .ordinary: ("普通内容", "General", "一般")
        case .adult: ("成人内容", "Adult", "成人向け")
        case .unclassified: ("待分类", "Unclassified", "未分類")
        case .special: ("特别关注", "Special follow", "特別フォロー")
        case .enabled: ("已启用", "Enabled", "有効")
        case .disabled: ("未启用", "Disabled", "無効")
        case .primary: ("主用", "Primary", "主モデル")
        case .backup: ("备用", "Backup", "予備モデル")
        case .verified: ("已验证", "Verified", "検証済み")
        case .unverified: ("未验证", "Unverified", "未検証")
        case .unpaired: ("未配对", "Unpaired", "未連携")
        case .paused: ("已暂停", "Paused", "一時停止")
        case .paired: ("已配对", "Paired", "連携済み")
        case .modelSlots: ("主备配置", "Model profiles", "モデル設定")
        case .world: ("国际新闻", "World News", "国際ニュース")
        case .japan: ("日本", "Japan", "日本")
        case .australia: ("澳洲", "Australia", "オーストラリア")
        case .china: ("中国", "China", "中国")
        case .electronics: ("科技数码", "Tech & Electronics", "テクノロジー")
        case .ai: ("AI 动态", "AI News", "AI ニュース")
        case .av: ("AV 产业", "AV Industry", "AV 業界")
        case .x: ("X 大事件", "X Highlights", "X の注目トピック")
        case .xAdult: ("X 成人博主", "Adult X Accounts", "X 成人向けアカウント")
        }
    }
}
