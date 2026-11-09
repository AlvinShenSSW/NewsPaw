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

        static let disappears = Words("完成后这个区域会自动消失。", "This list disappears once everything is done.", "すべて終わるとこの欄は消えます。")
        static let stepDone = Words("已完成", "Done", "完了")
        static let stepPending = Words("未完成", "Not done", "未完了")
        static let view = Words("查看", "View", "表示")
        static let turnOn = Words("去开启", "Turn On", "オンにする")
        static let connect = Words("去接入", "Connect", "接続する")

        static let all: [Words] = [title, bot, model, digest, delivery, done, disappears, stepDone, stepPending, view, turnOn, connect]
    }

    enum Overview {
        static let today = Words("今天的推送", "Today's deliveries", "今日の配信")
        static let showWeek = Words("最近 7 天 ›", "Last 7 days ›", "直近 7 日 ›")
        static let hideWeek = Words("收起 7 天", "Hide 7 days", "7 日分を閉じる")
        static let nothingToday = Words("今天没有安排推送。开启一份简报后会出现在这里。", "Nothing is scheduled today. Turn on a digest to see it here.", "今日の配信予定はありません。ダイジェストをオンにすると表示されます。")
        static let waiting = Words("等待中", "Waiting", "待機中")
        static let preparing = Words("准备中", "Preparing", "準備中")
        static let late = Words("延迟", "Late", "遅延")
        static let delivered = Words("已发送", "Sent", "送信済み")
        static let partial = Words("部分发送", "Partly sent", "一部送信")
        static let skipped = Words("已跳过", "Skipped", "スキップ")
        static let abandoned = Words("已放弃补发", "Resend abandoned", "再送を中止")
        static let unknown = Words("结果未知", "Result unknown", "結果不明")
        static let held = Words("等你决定", "Needs your decision", "判断待ち")
        static let failed = Words("未能发送", "Not sent", "送信できず")
        static let preparesAt = Words("{time} 开始准备", "Preparation starts at {time}", "{time} に準備開始")
        static let lateNote = Words("原定 {time}，正在补发", "Due at {time}, sending late", "予定 {time}、遅れて送信中")
        static let noNews = Words("没有合格的新条目", "No eligible new items", "条件に合う新着がありません")
        static let missed = Words("错过了补发时间", "The catch-up window passed", "再送の期限を過ぎました")
        static let superseded = Words("有更新的一期已经发出", "A newer edition was sent instead", "より新しい回を送りました")
        static let digestOff = Words("这份简报已关闭", "This digest was turned off", "このダイジェストはオフです")
        static let retimed = Words("发送时间改了，按新时间处理", "The time changed; the new time applies", "時刻が変わったため新しい時刻で扱います")
        static let noSuchTime = Words("这一天没有这个时间（夏令时切换）", "That time did not exist that day (clock change)", "その日はその時刻がありません（夏時間の切替）")
        static let modelUnknownNote = Words("写简报的模型调用发出去了但没收到结果，可能已经扣费。", "The model call was sent but no result came back; it may have been charged.", "モデル呼び出しの結果が返らず、課金された可能性があります。")
        static let deliveryUnknownNote = Words("Telegram 没有回应，这期可能已发出，也可能没有。", "Telegram did not answer; this edition may or may not have arrived.", "Telegram から応答がなく、届いたかどうか分かりません。")
        static let abandonedNote = Words("你选择了不再补发这一期。", "You chose not to resend this edition.", "この回は再送しないことにしました。")
        static let checkAndResend = Words("检查并补发", "Check and Resend", "確認して再送")
        static let retry = Words("确认后重试", "Retry", "再試行")
        static let stopResending = Words("不再补发", "Don't Resend", "再送しない")
        static let continueHeld = Words("继续发剩下的", "Send the Rest", "残りを送る")
        static let stopHeld = Words("停止", "Stop", "中止")
        static let heldBody = Words("这期已发出一部分，之后发送对象变了。", "Part of this edition was sent before its recipients changed.", "一部を送った後に送信先が変わりました。")
        static let retryModelTitle = Words("再调用一次模型？", "Call the model again?", "モデルをもう一度呼び出しますか？")
        static let retryModelBody = Words("上一次可能已经扣费，再试一次可能再扣一次。", "The last call may have been charged; trying again may charge again.", "前回は課金済みの可能性があり、再試行でもう一度課金されることがあります。")
        static let retryDeliveryTitle = Words("再发一次？", "Send again?", "もう一度送りますか？")
        static let retryDeliveryBody = Words("如果上次其实已经送到，你会收到两条。", "If the last attempt did arrive, you will get it twice.", "前回届いていた場合は 2 通届きます。")
        static let stopResendingTitle = Words("不再补发这一期？", "Stop resending this edition?", "この回の再送をやめますか？")
        static let stopResendingBody = Words("这一期（或其中这一段）将不再发送，之后也不会自动重试。", "This edition (or this part) will not be sent and will not be retried.", "この回（またはこの部分）は送信されず、自動で再試行もされません。")
        static let spending = Words("本月费用", "This month's spending", "今月の費用")
        static let ofCap = Words("/ 上限 {cap}", "of {cap} cap", "/ 上限 {cap}")
        static let noCap = Words("/ 不限", "no cap", "/ 上限なし")
        static let spendingDetail = Words("其中报纸生图 {image} · {unpriced} 次未计价", "Newspaper images {image} · {unpriced} unpriced calls", "新聞画像 {image}・未計価 {unpriced} 回")
        static let xToday = Words("X 今日读取", "X reads today", "X 本日の取得")
        static let sendNow = Words("立即发一期…", "Send One Now…", "今すぐ 1 回送る…")
        static let sendNowHelp = Words("为一份已开启的简报多发一期，每份每天一次。", "Send one extra edition of an enabled digest, once a day per digest.", "オンのダイジェストを 1 回追加で送ります（各 1 日 1 回）。")
        static let sendTrial = Words("立即试发一期", "Send a Trial Now", "今すぐ試しに送る")

        static let all: [Words] = [
            today, showWeek, hideWeek, nothingToday, waiting, preparing, late, delivered, partial, skipped,
            superseded, digestOff, retimed, noSuchTime,
            abandoned, unknown, held, failed, preparesAt, lateNote, noNews, missed, modelUnknownNote,
            deliveryUnknownNote, abandonedNote, checkAndResend, retry, stopResending, continueHeld, stopHeld,
            heldBody, retryModelTitle, retryModelBody, retryDeliveryTitle, retryDeliveryBody, stopResendingTitle,
            stopResendingBody, spending, ofCap, noCap, spendingDetail, xToday, sendNow, sendNowHelp, sendTrial,
        ]
    }

    enum Attention {
        static let title = Words("需要注意", "Worth a look", "確認が必要")
        static let keyRejected = Words("普通内容的模型 Key 没有通过测试", "The ordinary model key failed its check", "通常用モデルのキーが確認に失敗しました")
        static let keyRejectedNote = Words("在「接入」里看看具体原因并重新填入。", "See why under Connections and enter it again.", "「接続」で理由を確認して入れ直してください。")
        static let botWaiting = Words("{bot} 等待配对", "{bot} is waiting to pair", "{bot} はペアリング待ちです")
        static let botWaitingNote = Words("在 Telegram 里把配对码发给它。", "Send it the pairing code in Telegram.", "Telegram でペアリングコードを送ってください。")
        static let staleSource = Words("{source} 已 {days} 天没有新条目", "{source} has had nothing new for {days} days", "{source} は {days} 日間新着がありません")
        static let staleSourceNote = Words("用它的简报现在只能靠其他来源。", "Digests using it rely on their other sources.", "このソースを使うダイジェストは他のソースに頼っています。")
        static let capReached = Words("本月费用已到上限", "This month's cap is reached", "今月の上限に達しました")
        static let capReachedNote = Words("推送已暂停，提高上限或等下个月。", "Deliveries are paused; raise the cap or wait for next month.", "配信を止めています。上限を上げるか翌月を待ってください。")
        static let xUnlimited = Words("X 读取没有每日上限", "X reads have no daily cap", "X の取得に 1 日の上限がありません")
        static let xUnlimitedNote = Words("误加大量账号时可能耗尽额度，建议设一个上限。", "A large account list could use up your quota; consider a cap.", "大量のアカウントで枠を使い切らないよう上限を設定してください。")
        static let noBackup = Words("还没有备用模型", "No backup model yet", "予備モデルがまだありません")
        static let noBackupNote = Words("主模型出错时会跳过那一期。想要兜底可以给备用模型填一个 Key。", "If the main model fails, that edition is skipped. Add a key to the backup to cover it.", "主モデルが失敗するとその回は飛ばされます。予備モデルにキーを入れると補えます。")

        static let all: [Words] = [title, keyRejected, keyRejectedNote, botWaiting, botWaitingNote, staleSource, staleSourceNote, capReached, capReachedNote, xUnlimited, xUnlimitedNote, noBackup, noBackupNote]
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
        "no_target": Entry(message: Words("这份简报没有选发送到哪个机器人。", "This digest has no bot to send to.", "このダイジェストには送信先のボットがありません。"), action: nil),
        "target_unpaired": Entry(message: Words("要发送的机器人还没有配对。", "The bot it sends to is not paired yet.", "送信先のボットがまだペアリングされていません。"), action: nil),
        "missing_primary_credential": Entry(message: Words("模型还没有填 Key。", "The model has no key yet.", "モデルのキーがまだありません。"), action: nil),
        "no_sources": Entry(message: Words("这份简报还没有可用的来源。", "This digest has no usable source yet.", "このダイジェストには使える情報源がまだありません。"), action: nil),
        "missing_owner": Entry(message: Words("还没有和你的 Telegram 账号配对。", "Not paired with your Telegram account yet.", "まだ Telegram アカウントとペアリングしていません。"), action: nil),
        "preparation_failed": Entry(message: Words("准备简报时出错，下一期会重新尝试。", "Preparing the digest failed; the next edition tries again.", "ダイジェストの準備に失敗しました。次の回で再試行します。"), action: nil),
        "collection_failed": Entry(message: Words("所有来源都没取到内容。", "None of the sources could be read.", "どの情報源からも取得できませんでした。"), action: nil),
        "schedule_changed": Entry(message: Words("发送时间改了，这期按新时间处理。", "The time changed, so this edition follows the new time.", "時刻が変わったため、この回は新しい時刻で扱います。"), action: nil),
        "digest_not_enabled": Entry(message: Words("这份简报还没开启，开启后才能试发。", "Turn this digest on before sending one now.", "今すぐ送るには先にダイジェストをオンにしてください。"), action: nil),
        "scheduling_paused": Entry(message: Words("全部推送已暂停，恢复后才能发送。", "All deliveries are paused; resume them first.", "すべての配信が一時停止中です。先に再開してください。"), action: nil),
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
