import Foundation

/// One user-visible string in all three interface languages. The initializer requires
/// every language, so a missing translation does not compile.
struct Words: Equatable, Sendable {
    let zh: String
    let en: String
    let ja: String

    init(_ zh: String, _ en: String, _ ja: String) {
        self.zh = zh
        self.en = en
        self.ja = ja
    }

    func callAsFunction(_ language: AppLanguage) -> String {
        switch language {
        case .zhHans: zh
        case .en: en
        case .ja: ja
        }
    }

    /// `{name}` placeholders filled after translation; values are user data, never translated.
    func callAsFunction(_ language: AppLanguage, _ values: [String: String]) -> String {
        values.reduce(self(language)) { text, item in text.replacingOccurrences(of: "{\(item.key)}", with: item.value) }
    }
}

/// The redesigned app's vocabulary (interaction-spec §0.2), grouped by where it appears.
enum L10n {
    enum Shell {
        static let tagline = Words("你的新闻伙伴", "Your news companion", "ニュースの相棒")
        static let running = Words("后台运行中", "Backend running", "バックエンド稼働中")
        static let connecting = Words("正在连接后台", "Connecting to the backend", "バックエンドに接続中")
        static let notRunning = Words("后台没有运行", "The backend is not running", "バックエンドが動いていません")
        static let stopping = Words("后台正在停止", "The backend is stopping", "バックエンドを停止中")
        static let incompatible = Words("后台版本和这个窗口不匹配", "This window does not match the backend version", "このウインドウとバックエンドのバージョンが合いません")
        static let paused = Words("已暂停全部推送", "All deliveries paused", "すべての配信を一時停止中")
        static let notRunningNote = Words(
            "NewsPaw 的推送由一个后台程序完成，它会在登录时自动启动。",
            "A background program delivers NewsPaw digests and starts when you log in.",
            "NewsPaw の配信はバックグラウンドのプログラムが行い、ログイン時に自動で起動します。"
        )
        static let openNewsPaw = Words("打开 NewsPaw", "Open NewsPaw", "NewsPaw を開く")
        static let pauseAll = Words("暂停全部推送", "Pause All Deliveries", "すべての配信を一時停止")
        static let resumeAll = Words("恢复推送", "Resume Deliveries", "配信を再開")
        static let quitWindow = Words("退出 NewsPaw 界面", "Quit NewsPaw Window", "NewsPaw の画面を終了")
        static let quitNote = Words(
            "关闭这个窗口不会停止后台，后台会一直在菜单栏里。",
            "Closing this window does not stop the backend; it stays in the menu bar.",
            "このウインドウを閉じてもバックエンドは止まらず、メニューバーに残ります。"
        )
        static let refresh = Words("刷新", "Refresh", "更新")
        static let stopBackend = Words("停止后台", "Stop Backend", "バックエンドを停止")
        static let stopTitle = Words("停止后台？", "Stop the backend?", "バックエンドを停止しますか？")
        static let stopBody = Words(
            "停止后不会再推送，直到你再次打开 NewsPaw。",
            "Nothing will be delivered until you open NewsPaw again.",
            "NewsPaw をもう一度開くまで配信されません。"
        )
        static let cancel = Words("取消", "Cancel", "キャンセル")
        static let stopFailed = Words("没能确认后台已经停止。", "Could not confirm that the backend stopped.", "バックエンドの停止を確認できませんでした。")
        static let retry = Words("重试", "Try Again", "再試行")
        static let savedAt = Words("已自动保存 · {time}", "Saved automatically · {time}", "自動保存済み · {time}")

        static let all: [Words] = [
            tagline, running, connecting, notRunning, stopping, incompatible, paused, notRunningNote,
            openNewsPaw, pauseAll, resumeAll, quitWindow, quitNote, refresh, stopBackend, stopTitle,
            stopBody, cancel, stopFailed, retry, savedAt,
        ]
    }

    enum Page {
        static let overview = Words("概览", "Overview", "概要")
        static let digests = Words("简报", "Digests", "ダイジェスト")
        static let xAccounts = Words("X 账号", "X Accounts", "X アカウント")
        static let connect = Words("接入", "Connections", "接続")
        static let settings = Words("设置", "Settings", "設定")

        static let all: [Words] = [overview, digests, xAccounts, connect, settings]
    }

    enum Setup {
        static let title = Words("还差 {count} 步，就能收到第一份简报", "{count} more steps to your first digest", "最初のダイジェストまであと {count} ステップ")
        static let bot = Words("连接 Telegram 机器人", "Connect a Telegram bot", "Telegram ボットを接続")
        static let model = Words("填入并验证模型 Key", "Add and check a model key", "モデルのキーを追加して確認")
        static let digest = Words("选择要收的简报", "Choose your digests", "受け取るダイジェストを選ぶ")
        static let delivery = Words("收到第一份简报", "Receive your first digest", "最初のダイジェストを受け取る")
        static let done = Words("设置完成，后台会按时推送。", "Setup is complete; digests arrive on schedule.", "設定は完了しました。予定どおり配信されます。")

        static let all: [Words] = [title, bot, model, digest, delivery, done]
    }
}

/// "What happened. What to do." for a backend code (interaction-spec §2.4).
enum FailureCopy {
    struct Entry: Sendable {
        let message: Words
        let action: Words?
    }

    static let table: [String: Entry] = [
        "invalid_token": Entry(message: Words("Telegram 不认这个 Token。请到 @BotFather 复制完整 Token 再试。", "Telegram did not accept this token. Copy the full token from @BotFather and try again.", "Telegram がこのトークンを受け付けませんでした。@BotFather から完全なトークンをコピーしてやり直してください。"), action: Words("重新粘贴", "Paste Again", "貼り直す")),
        "webhook_conflict": Entry(message: Words("这个机器人正被别的程序用 webhook 接管。关掉那边后再验证。", "Another program controls this bot through a webhook. Turn that off, then check again.", "別のプログラムが Webhook でこのボットを使っています。そちらを止めてから再確認してください。"), action: Words("重新验证", "Check Again", "再確認")),
        "duplicate_bot": Entry(message: Words("这个机器人已经添加过了。", "This bot is already added.", "このボットは追加済みです。"), action: nil),
        "pair_expired": Entry(message: Words("配对码过期了。", "The pairing code expired.", "ペアリングコードの期限が切れました。"), action: Words("重新生成", "New Code", "再発行")),
        "pair_attempts_exhausted": Entry(message: Words("连续输错 5 次，这个码作废了。", "Five wrong attempts used up this code.", "5 回間違えたため、このコードは無効になりました。"), action: Words("重新生成", "New Code", "再発行")),
        "rate_limited": Entry(message: Words("对方服务说请求太频繁。稍等一分钟再试。", "The service asked us to slow down. Try again in a minute.", "サービス側から頻度の制限を受けました。1 分ほど待って再試行してください。"), action: Words("再试一次", "Try Again", "再試行")),
        "transport_error": Entry(message: Words("网络没有连上对方服务。检查网络后再试。", "Could not reach the service. Check the network and try again.", "サービスに接続できませんでした。ネットワークを確認して再試行してください。"), action: Words("再试一次", "Try Again", "再試行")),
        "timeout": Entry(message: Words("对方服务没有及时回应。", "The service did not respond in time.", "サービスが時間内に応答しませんでした。"), action: Words("再试一次", "Try Again", "再試行")),
        "keychain_locked": Entry(message: Words("钥匙串被锁定，解锁后 NewsPaw 才能读到 Key。", "The keychain is locked; unlock it so NewsPaw can read your keys.", "キーチェーンがロックされています。解除するとキーを読み取れます。"), action: nil),
        "unsafe_url": Entry(message: Words("这个链接指向内网或带有凭据，不能添加。", "This link points to a private network or carries credentials, so it cannot be added.", "このリンクは内部ネットワークを指しているか認証情報を含むため追加できません。"), action: nil),
        "unsupported_source": Entry(message: Words("还不会读这个网站，只能先存为待验证。", "NewsPaw cannot read this site yet; it is saved as unverified.", "このサイトはまだ読めないため、未確認として保存しました。"), action: nil),
        "monthly_limit": Entry(message: Words("本月费用已到上限，推送已暂停。", "This month's spending cap is reached, so deliveries are paused.", "今月の上限に達したため配信を止めています。"), action: Words("调整上限", "Change Cap", "上限を変更")),
        "service_stopping": Entry(message: Words("后台正在停止，这个改动没有保存。", "The backend is stopping, so this change was not saved.", "バックエンドが停止中のため、この変更は保存されませんでした。"), action: nil),
        "backend_unreachable": Entry(message: Words("后台没有回应。确认 NewsPaw 后台正在运行后再试。", "The backend did not answer. Make sure it is running, then try again.", "バックエンドが応答しません。動作中か確認してから再試行してください。"), action: Words("再试一次", "Try Again", "再試行")),
        "invalid_reply": Entry(message: Words("后台的回应看不懂，可能是版本不一致。", "The backend reply was not understood; the versions may differ.", "バックエンドの応答を解釈できません。バージョンが違う可能性があります。"), action: nil),
        "internal_error": Entry(message: Words("NewsPaw 内部出了问题，已记录在日志里。", "NewsPaw hit an internal problem and logged it.", "NewsPaw 内部で問題が起き、ログに記録しました。"), action: nil),
    ]

    static let conflict = Entry(
        message: Words("这项刚被别处改过，已重新载入，请再改一次。", "This changed elsewhere and was reloaded; please make your change again.", "別の場所で変更されたため再読み込みしました。もう一度変更してください。"),
        action: nil
    )

    static let fallback = Words(
        "没有完成（{code}）。请再试一次；仍然不行可以在「设置 › 高级」导出诊断信息。",
        "That did not complete ({code}). Try again; if it keeps failing, export diagnostics from Settings › Advanced.",
        "完了しませんでした（{code}）。もう一度お試しください。続く場合は「設定 › 詳細」から診断情報を書き出してください。"
    )

    static func entry(for error: BackendError) -> Entry {
        if error.isConflict { return conflict }
        return table[error.code] ?? Entry(message: fallback, action: error.retryable ? L10n.Shell.retry : nil)
    }

    static func message(for error: BackendError, _ language: AppLanguage) -> String {
        let entry = entry(for: error)
        return entry.message(language, ["code": error.code])
    }
}
