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
            "停止后菜单栏将不再推送，直到你再次打开 NewsPaw。",
            "Once stopped, the menu bar delivers nothing until you open NewsPaw again.",
            "停止すると、NewsPaw をもう一度開くまでメニューバーから配信されません。"
        )
        static let cancel = Words("取消", "Cancel", "キャンセル")
        static let stopFailed = Words("没能确认后台已经停止。", "Could not confirm that the backend stopped.", "バックエンドの停止を確認できませんでした。")
        static let retry = Words("重试", "Try Again", "再試行")
        static let savedAt = Words("已自动保存 · {time}", "Saved automatically · {time}", "自動保存済み · {time}")

        static let all: [Words] = [
            tagline, running, connecting, notRunning, stopping, incompatible, paused, notRunningNote,
            openNewsPaw, pauseAll, quitWindow, quitNote, refresh, stopBackend, stopTitle,
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
        static let jobPaused = Words("已暂停", "Paused", "一時停止中")
        static let jobPausedNote = Words("这一期被暂停了（在 Telegram 或这里），继续后会接着准备。", "This edition was paused (in Telegram or here); resuming continues preparing it.", "この回は一時停止されています（Telegram またはここで）。再開すると準備を続けます。")
        static let resume = Words("继续", "Resume", "再開")
        static let resumeTitle = Words("继续这一期？", "Resume this edition?", "この回を再開しますか？")
        static let modelExpiredNote = Words("模型的结果不确定，补发时间已过，这一期不会再发。", "The model's result is unknown and the time to retry has passed; this edition will not be sent.", "モデルの結果が不明で、再試行の期限を過ぎました。この回は送られません。")
        static let partialSettledNote = Words("部分已发出，其余这期不会再发。", "Part of this edition arrived; the rest will not be sent.", "一部は届きました。残りは送られません。")
        static let retryExpiredNote = Words("Telegram 没有回应，这期可能已发出。补发时间已过，只能选择不再补发。", "Telegram did not answer; this edition may have arrived. The time to resend has passed, so it can only be marked as not resent.", "Telegram から応答がなく、届いた可能性があります。再送の期限を過ぎたため、再送しない扱いにするしかありません。")
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
            deliveryUnknownNote, abandonedNote, partialSettledNote, retryExpiredNote, jobPaused, jobPausedNote, resume, resumeTitle, modelExpiredNote, checkAndResend, retry, stopResending, continueHeld, stopHeld,
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

    enum Onboarding {
        static let windowTitle = Words("设置 NewsPaw", "Set Up NewsPaw", "NewsPaw の設定")
        static let openSetup = Words("首次设置…", "Setup Assistant…", "初期設定…")
        static let telegramTitle = Words("连接 Telegram", "Connect Telegram", "Telegram を接続")
        static let modelTitle = Words("模型 Key", "Model Key", "モデルのキー")
        static let digestsTitle = Words("选择简报", "Choose Digests", "ダイジェストを選ぶ")
        static let current = Words("当前步骤", "Current step", "現在のステップ")
        static let stepDone = Words("已完成", "Done", "完了")
        static let stepPending = Words("未完成", "Not done", "未完了")
        static let skip = Words("先跳过，稍后在「接入」里填", "Skip for now; finish later in Connect", "今はスキップ（あとで「接続」で設定）")
        static let finishLater = Words("先关闭，稍后再选", "Close and choose later", "閉じてあとで選ぶ")
        static let back = Words("上一步", "Back", "戻る")
        static let next = Words("继续", "Continue", "続ける")
        static let finishAndSend = Words("完成并试发一期", "Finish and Send a Trial", "完了して試しに送る")
        static let finishQuietly = Words("完成，等定时推送", "Finish and Wait for the Schedule", "完了して定時配信を待つ")
        static let telegramIntro = Words("在 Telegram 里找 @BotFather 新建一个机器人，把它给你的 Token 粘贴到这里。", "In Telegram, ask @BotFather for a new bot and paste the token it gives you here.", "Telegram の @BotFather で新しいボットを作り、受け取ったトークンをここに貼り付けてください。")
        static let howTo = Words("怎么做？", "How?", "方法")
        static let tokenPlaceholder = Words("Bot Token", "Bot token", "ボットのトークン")
        static let check = Words("验证", "Check", "確認")
        static let checking = Words("正在验证…", "Checking…", "確認中…")
        static let verified = Words("已验证 · {name}", "Verified · {name}", "確認済み · {name}")
        static let sendThis = Words("在 Telegram 里打开 {name}，发送：", "Open {name} in Telegram and send:", "Telegram で {name} を開き、次を送ってください：")
        static let copy = Words("复制", "Copy", "コピー")
        static let expiresIn = Words("{minutes} 分 {seconds} 秒后失效 · 正在等你发送", "Expires in {minutes} min {seconds} s · waiting for you", "あと {minutes} 分 {seconds} 秒で期限切れ · 送信を待っています")
        static let expired = Words("配对码过期了。", "The pairing code expired.", "ペアリングコードの期限が切れました。")
        static let newCode = Words("重新生成", "New Code", "再発行")
        static let paired = Words("已配对 · {time}", "Paired · {time}", "ペアリング済み · {time}")
        static let saveToUse = Words("换了模型：保存 Key 后才会使用它。", "Model changed: save a key to start using it.", "モデルを変更しました。キーを保存すると使われます。")
        static let pairedEarlier = Words("已配对", "Paired", "ペアリング済み")
        static let notPaired = Words("机器人已验证，但还没配对。", "The Bot is verified but not paired yet.", "ボットは確認済みですが、まだペアリングされていません。")
        static let moreBots = Words("这里只接一个机器人；还可以在「接入」里再加一个只收成人内容的机器人。", "This connects one Bot; you can add another, for adult content only, in Connect.", "ここでは 1 つだけ接続します。成人向け専用のボットは「接続」で追加できます。")
        static let modelIntro = Words("NewsPaw 用你的模型 Key 挑选和整理新闻。保存后会自动发一条很短的测试消息。", "NewsPaw uses your model key to choose and write up news. Saving it sends one very short test message.", "NewsPaw はあなたのモデルのキーでニュースを選んでまとめます。保存すると短いテストメッセージを 1 回送ります。")
        static let whichModel = Words("模型", "Model", "モデル")
        static let luna = Words("GPT-6 Luna（OpenAI）· 推荐", "GPT-6 Luna (OpenAI) · Recommended", "GPT-6 Luna（OpenAI）· おすすめ")
        static let mimo = Words("MiMo Flash（小米）", "MiMo Flash (Xiaomi)", "MiMo Flash（Xiaomi）")
        static let custom = Words("自定义…", "Custom…", "カスタム…")
        static let customURL = Words("API 地址（兼容 OpenAI）", "API address (OpenAI-compatible)", "API アドレス（OpenAI 互換）")
        static let customModel = Words("模型 ID", "Model ID", "モデル ID")
        static let keyPlaceholder = Words("API Key", "API key", "API キー")
        static let paste = Words("粘贴", "Paste", "貼り付け")
        static let saveAndCheck = Words("保存并测试", "Save and Check", "保存して確認")
        static let checkingKey = Words("正在测试 Key…", "Checking the key…", "キーを確認中…")
        static let keyPassed = Words("测试通过 · 刚才发了一条很短的测试消息，模型正常回复（{model}）", "Check passed · a very short test message got a normal reply ({model})", "確認できました · 短いテストメッセージに正常な返答がありました（{model}）")
        static let checkAgain = Words("再测一次", "Check Again", "もう一度確認")
        static let adultOptional = Words("我也想看 AV 产业 / X 成人博主 · 可选", "I also want AV industry / X adult accounts · optional", "AV 業界 / X 成人向けも見たい · 任意")
        static let adultNote = Words("成人内容用单独的 DeepSeek Key，和普通新闻分开。", "Adult content uses a separate DeepSeek key, kept apart from ordinary news.", "成人向けは別の DeepSeek キーを使い、通常のニュースとは分けます。")
        static let advanced = Words("高级：备用模型", "Advanced: backup model", "詳細：予備モデル")
        static let backupNote = Words("主模型出错时改用 MiMo Flash。", "MiMo Flash is used when the main model fails.", "メインモデルが失敗したときは MiMo Flash を使います。")
        static let costNote = Words("费用由你自己的模型账号承担。NewsPaw 默认每月最多花 $20，可在「接入」里改或清空。", "Costs are billed to your own model account. NewsPaw spends at most $20 a month by default; change or clear it in Connect.", "費用はあなたのモデルのアカウントに請求されます。既定では月 $20 までで、「接続」で変更・解除できます。")
        static let sendTo = Words("会发到 {bot}", "Sent {bot}", "{bot} に送ります")
        static let chooseLater = Words("有多个机器人：开启后在「简报」里选择发到哪个。", "Several Bots: choose where each digest goes on the Digests page.", "ボットが複数あります。送信先は「ダイジェスト」で選んでください。")
        static let all: [Words] = [
            windowTitle, openSetup, telegramTitle, modelTitle, digestsTitle, current, stepDone, stepPending, skip, finishLater,
            back, next, finishAndSend, finishQuietly, telegramIntro, howTo, tokenPlaceholder, check, checking, verified,
            sendThis, copy, expiresIn, expired, newCode, paired, moreBots, modelIntro, whichModel, luna, mimo, custom,
            customURL, customModel, keyPlaceholder, paste, saveAndCheck, checkingKey, keyPassed, checkAgain, adultOptional,
            adultNote, advanced, backupNote, costNote, sendTo, chooseLater, pairedEarlier, notPaired, saveToUse,
        ]
    }

    enum Digests {
        static let intro = Words("每份简报按自己的时间发到你选的机器人。改动会自动保存。", "Each digest goes to the Bots you choose at its own times. Changes save automatically.", "ダイジェストはそれぞれの時刻に、選んだボットへ届きます。変更は自動で保存されます。")
        static let importOPML = Words("导入 OPML", "Import OPML", "OPML を読み込む")
        static let importSummary = Words("新增 {added} 个来源，{existing} 个已存在，跳过 {rejected} 个。", "{added} new sources, {existing} already here, {rejected} skipped.", "新しいソース {added} 件、既存 {existing} 件、スキップ {rejected} 件。")
        static let importInto = Words("加到", "Add to", "追加先")
        static let importNote = Words("导入的来源都是待验证，在简报里试采集后启用。", "Imported sources wait for a trial; try them in the digest to turn them on.", "読み込んだソースは未確認です。ダイジェストで試しに取得してから有効にします。")
        static let done = Words("完成", "Done", "完了")
        static let later = Words("稍后", "Later", "あとで")
        static let add = Words("添加", "Add", "追加")
        static let adult = Words("成人", "Adult", "成人向け")
        static let completeSetup = Words("去接入补齐", "Finish in Connect", "接続で設定する")
        static let enabled = Words("开启", "On", "オン")
        static let edit = Words("编辑", "Edit", "編集")
        static let collapse = Words("收起", "Close", "閉じる")
        static let offTitle = Words("关闭「{name}」？", "Turn off \u{201C}{name}\u{201D}?", "「{name}」をオフにしますか？")
        static let turnOff = Words("关闭", "Turn Off", "オフにする")
        static let offBody = Words("来源和设置都会保留。", "Its sources and settings are kept.", "ソースと設定はそのまま残ります。")
        static let offBodyToday = Words("今天 {time} 的那期不会发；来源和设置都会保留。", "Today's {time} edition will not be sent; its sources and settings are kept.", "今日 {time} の回は送られません。ソースと設定はそのまま残ります。")
        static let offPrefix = Words("关闭中", "Off", "オフ")
        static let needsAdultSetup = Words("需要成人模型 Key 和一个允许成人内容的机器人", "Needs an adult model key and a Bot that allows adult content", "成人向けモデルのキーと、成人向けを許可したボットが必要です")
        static let needsBot = Words("需要先接入一个 Telegram 机器人", "Connect a Telegram Bot first", "先に Telegram ボットを接続してください")
        static let noTarget = Words("还没选机器人", "no Bot chosen", "ボット未選択")
        static let offSummary = Words("关闭中 · 开启后每天 {times} · {sources}", "Off · when on, every day at {times} · {sources}", "オフ · オンにすると毎日 {times} · {sources}")
        static let sourceCount = Words("{count} 个来源", "{count} sources", "ソース {count} 件")
        static let recommendedCount = Words("推荐 {count} 个来源", "{count} recommended sources", "おすすめソース {count} 件")
        static let everyDay = Words("每天 {times}", "Every day at {times}", "毎日 {times}")
        static let next = Words("下一期 {when}", "next {when}", "次回 {when}")
        static let today = Words("今天 {time}", "today {time}", "今日 {time}")
        static let tomorrow = Words("明天 {time}", "tomorrow {time}", "明日 {time}")
        static let botCount = Words("{count} 个机器人", "{count} Bots", "ボット {count} 件")
        static let times = Words("发送时间", "Send at", "送信時刻")
        static let sendTo = Words("发送到", "Send to", "送信先")
        static let count = Words("每期条数", "Items", "件数")
        static let upTo = Words("最多 {count} 条", "Up to {count}", "最大 {count} 件")
        static let countNote = Words("新闻不够时少发，不凑数。", "Fewer when there is less news; never padded.", "ニュースが少ない日は少なめに送り、水増ししません。")
        static let style = Words("样式", "Style", "スタイル")
        static let styleText = Words("文字 + 链接", "Text + links", "テキスト + リンク")
        static let styleImage = Words("带来源配图", "With source images", "ソース画像つき")
        static let stylePaper = Words("AI 报纸", "AI newspaper", "AI 新聞")
        static let paperNeedsSetup = Words("需要先在「接入 › 附加能力」开启生图", "Turn on image generation in Connect › Extras first", "先に「接続 › 追加機能」で画像生成をオンにしてください")
        static let goConnect = Words("去开启", "Turn On", "オンにする")
        static let ratio = Words("国内 / 娱乐", "Domestic / Entertainment", "国内 / エンタメ")
        static let domestic = Words("国内 {value}%", "Domestic {value}%", "国内 {value}%")
        static let entertainment = Words("娱乐 {value}%", "Entertainment {value}%", "エンタメ {value}%")
        static let domesticTag = Words("国内", "Domestic", "国内")
        static let entertainmentTag = Words("娱乐", "Entertainment", "エンタメ")
        static let advanced = Words("高级", "Advanced", "詳細")
        static let removeTitle = Words("移除「{name}」？", "Remove \u{201C}{name}\u{201D}?", "「{name}」を削除しますか？")
        static let remove = Words("移除", "Remove", "削除")
        static let removeBody = Words("这个来源会从所有简报中移除。", "The source is removed from every digest.", "このソースはすべてのダイジェストから削除されます。")
        static let removeTurnsOff = Words("移除后这些简报会因为没有来源而关闭：{names}", "These digests will turn off because they have no other source: {names}", "ほかにソースがないため、次のダイジェストがオフになります：{names}")
        static let splitTitle = Words("把「{name}」拆成两份？", "Split \u{201C}{name}\u{201D} in two?", "「{name}」を 2 つに分けますか？")
        static let split = Words("拆成两份", "Split in Two", "2 つに分ける")
        static let splitBody = Words("各自有时间和机器人；现有来源按国内 / 娱乐分配。新的一份先关闭。", "Each gets its own times and Bots; sources are divided by domestic / entertainment. The new one starts off.", "それぞれに時刻とボットを設定できます。ソースは国内 / エンタメで分けます。新しい方はオフで始まります。")
        static let mergeTitle = Words("并回「{name}」？", "Merge back into \u{201C}{name}\u{201D}?", "「{name}」に戻しますか？")
        static let merge = Words("并回", "Merge Back", "戻す")
        static let mergeInto = Words("并回「{name}」", "Merge Back into \u{201C}{name}\u{201D}", "「{name}」に戻す")
        static let mergeBody = Words("这一份会删除，它的推送记录保留；剩下的一份重新使用全部来源。", "This one is deleted and its delivery history kept; the remaining one uses all sources again.", "こちらは削除され、配信履歴は残ります。残る方はすべてのソースを使います。")
        static let removeTime = Words("删除这个时间", "Remove This Time", "この時刻を削除")
        static let addTime = Words("＋ 加一个时间", "+ Add a Time", "＋ 時刻を追加")
        static let zone = Words("时区 {zone} · 改", "Time zone {zone} · Change", "タイムゾーン {zone} · 変更")
        static let followsSystem = Words("（跟随系统）", " (system)", "（システム）")
        static let addBot = Words("先接入一个机器人", "Connect a Bot first", "先にボットを接続")
        static let botNotAdult = Words("不接收成人内容", "Does not take adult content", "成人向けを受け取らない")
        static let botNotPaired = Words("还没配对", "Not paired yet", "未ペアリング")
        static let onlyBot = Words("只有一个可用机器人时会自动选中。", "With only one usable Bot, it is chosen automatically.", "使えるボットが 1 つだけのときは自動で選ばれます。")
        static let sourcesTitle = Words("来源 · {count} 个启用", "Sources · {count} on", "ソース · {count} 件オン")
        static let fromCatalog = Words("从推荐目录添加", "Add from Catalog", "おすすめから追加")
        static let pasteLink = Words("粘贴链接", "Paste a Link", "リンクを貼り付け")
        static let noSources = Words("还没有来源。开启简报会自动带入推荐来源。", "No sources yet. Turning the digest on brings in recommended ones.", "ソースはまだありません。オンにするとおすすめが入ります。")
        static let catalogEmpty = Words("推荐目录里的来源都已添加。", "Every catalog source is already added.", "おすすめのソースはすべて追加済みです。")
        static let notReadable = Words("还不会读这个网站", "Cannot read this site yet", "このサイトはまだ読めません")
        static let pastePlaceholder = Words("网站或 RSS 链接", "Website or RSS link", "サイトまたは RSS のリンク")
        static let reading = Words("正在读取…", "Reading…", "読み込み中…")
        static let identify = Words("识别", "Identify", "確認")
        static let primaryModel = Words("主模型", "Main model", "メインモデル")
        static let backupModel = Words("备用模型", "Backup model", "予備モデル")
        static let defaultModel = Words("跟随默认", "Default", "デフォルト")
        static let pauseThis = Words("暂停这份简报", "Pause This Digest", "このダイジェストを一時停止")
        static let sent = Words("已发送", "Sent", "送信済み")
        static let view = Words("查看", "View", "見る")
        static let preview = Words("预览这期会选什么", "Preview This Edition", "今回の内容をプレビュー")
        static let previewReady = Words("将从 {sources} 个来源选最多 {count} 条，{bots}", "Up to {count} items from {sources} sources, {bots}", "{sources} 件のソースから最大 {count} 件、{bots}")
        static let send = Words("发送", "Send", "送信")
        static let trialResult = Words("取到 {count} 条，最新 {time}", "Got {count} items, latest {time}", "{count} 件取得、最新 {time}")
        static let unverified = Words("待验证", "Not tried yet", "未確認")
        static let unreadable = Words("读不到", "Unreadable", "読めません")
        static let staleDays = Words("{days} 天没更新", "No update for {days} days", "{days} 日更新なし")
        static let healthy = Words("正常", "Healthy", "正常")
        static let unknownHealth = Words("还没有记录", "No record yet", "記録なし")
        static let tryThenEnable = Words("试采集后启用", "Try, Then Turn On", "試してからオン")
        static let tryNow = Words("试采集", "Try Now", "試しに取得")
        static let more = Words("更多", "More", "その他")
        static let latest = Words("最近 {time}", "latest {time}", "最新 {time}")
        static let searchZone = Words("搜索时区", "Search time zones", "タイムゾーンを検索")
        static let systemZone = Words("跟随系统（{zone}）", "Use system ({zone})", "システムに合わせる（{zone}）")
        static let adultOnly = Words("成人内容，只能加到成人简报", "Adult content; only for an adult digest", "成人向け。成人向けダイジェストにのみ追加できます")
        static let notAdult = Words("普通内容，不能加到成人简报", "Ordinary content; not for an adult digest", "通常のコンテンツ。成人向けダイジェストには追加できません")
        static let mutedFocus = Words("比例为 0%，在「国内 / 娱乐」里调整", "Set to 0% by the domestic / entertainment ratio", "「国内 / エンタメ」の比率が 0% です")
        static let unfiled = Words("{count} 个导入的来源还没归入简报", "{count} imported sources are not in a digest yet", "読み込んだソース {count} 件がまだダイジェストに入っていません")
        static let fileThem = Words("归入简报…", "Add to a Digest…", "ダイジェストに追加…")
        static let fileTitle = Words("归入简报", "Add to a Digest", "ダイジェストに追加")
        static let botPaused = Words("已暂停", "Paused", "一時停止中")
        static let all: [Words] = [
            intro, importOPML, importSummary, importInto, importNote, done, later, add, adult, completeSetup, enabled, edit, collapse,
            offTitle, turnOff, offBody, offBodyToday, offPrefix, needsAdultSetup, needsBot, noTarget, offSummary, sourceCount,
            recommendedCount, everyDay, next, today, tomorrow, botCount, times, sendTo, count, upTo, countNote, style, styleText,
            styleImage, stylePaper, paperNeedsSetup, goConnect, ratio, domestic, entertainment, domesticTag, entertainmentTag,
            advanced, removeTitle, remove, removeBody, removeTurnsOff, splitTitle, split, splitBody, mergeTitle, merge, mergeInto,
            mergeBody, removeTime, addTime, zone, followsSystem, addBot, botNotAdult, botNotPaired, onlyBot, sourcesTitle,
            fromCatalog, pasteLink, noSources, catalogEmpty, notReadable, pastePlaceholder, reading, identify, primaryModel,
            backupModel, defaultModel, pauseThis, sent, view, preview, previewReady, send, trialResult, unverified, unreadable,
            staleDays, healthy, unknownHealth, tryThenEnable, tryNow, more, latest, searchZone, systemZone,
            unfiled, fileThem, fileTitle, botPaused, adultOnly, notAdult, mutedFocus,
        ]
    }

    enum Connect {
        static let intro = Words("Telegram 机器人、模型和费用上限。所有 Key 只存在这台 Mac 的钥匙串里。", "Telegram bots, models and spending limits. Every key stays in this Mac's keychain.", "Telegram ボット、モデル、費用の上限。キーはすべてこの Mac のキーチェーンにだけ保存されます。")
        static let todayAt = Words("今天 {time}", "today {time}", "今日 {time}")
        static let yesterdayAt = Words("昨天 {time}", "yesterday {time}", "昨日 {time}")
        static let save = Words("保存", "Save", "保存")
        static let saving = Words("正在保存…", "Saving…", "保存中…")
        static let botsTitle = Words("Telegram 机器人", "Telegram Bots", "Telegram ボット")
        static let addBot = Words("添加机器人", "Add Bot", "ボットを追加")
        static let noBots = Words("还没有机器人。添加一个后，简报才有地方发。", "No bots yet. Add one so your digests have somewhere to go.", "まだボットがありません。追加するとダイジェストの送り先ができます。")
        static let receives = Words("接收 {count} 份简报：{names}", "Receives {count} digests: {names}", "{count} 件のダイジェストを受信：{names}")
        static let receivesNone = Words("还没有简报发到这里", "No digest is sent here yet", "まだどのダイジェストも送られていません")
        static let rename = Words("改名", "Rename", "名前を変更")
        static let statusUnverified = Words("未验证", "Not checked", "未確認")
        static let statusWaiting = Words("等待配对", "Waiting to pair", "ペアリング待ち")
        static let statusPaired = Words("已配对", "Paired", "ペアリング済み")
        static let statusPaused = Words("已暂停", "Paused", "一時停止中")
        static let statusUnpaired = Words("已解除配对", "Unpaired", "ペアリング解除済み")
        static let statusProblem = Words("需要处理", "Needs attention", "対応が必要")
        static let sendTest = Words("发测试消息", "Send Test Message", "テストメッセージを送信")
        static let sending = Words("正在发送…", "Sending…", "送信中…")
        static let testSent = Words("已发到你的 Telegram · {time}", "Sent to your Telegram · {time}", "Telegram に送信しました · {time}")
        static let testUnknown = Words("Telegram 没有回应，测试消息可能已发出，也可能没有。", "Telegram did not answer; the test message may or may not have arrived.", "Telegram から応答がなく、テストメッセージが届いたか分かりません。")
        static let checkResult = Words("检查结果", "Check Result", "結果を確認")
        static let testStillUnknown = Words("还是不能确定。看看 Telegram 里有没有收到；没有就再发一次。", "Still unclear. See whether it arrived in Telegram; if not, send another.", "まだ分かりません。Telegram に届いたか確認し、届いていなければもう一度送ってください。")
        static let testNotSent = Words("这条测试消息没有发出去。可以再发一次。", "This test message was not sent. You can send another.", "このテストメッセージは送信されませんでした。もう一度送れます。")
        static let sendAgain = Words("再发一次", "Send Again", "もう一度送信")
        static let more = Words("更多", "More", "その他")
        static let pause = Words("暂停", "Pause", "一時停止")
        static let resume = Words("恢复", "Resume", "再開")
        static let replaceToken = Words("更换 Token…", "Replace Token…", "トークンを変更…")
        static let unpair = Words("解除配对…", "Unpair…", "ペアリングを解除…")
        static let delete = Words("删除机器人…", "Delete Bot…", "ボットを削除…")
        static let unpairTitle = Words("解除和 {name} 的配对？", "Unpair {name}?", "{name} のペアリングを解除しますか？")
        static let unpairBody = Words("解除后它不会再收到简报，直到重新配对。", "It receives no digests until you pair it again.", "再びペアリングするまでダイジェストは届きません。")
        static let unpairButton = Words("解除配对", "Unpair", "ペアリングを解除")
        static let deleteTitle = Words("删除 {name}？", "Delete {name}?", "{name} を削除しますか？")
        static let deleteButton = Words("删除", "Delete", "削除")
        static let deleteNone = Words("没有简报发到它，删除不影响推送。", "No digest is sent to it; deleting changes no delivery.", "どのダイジェストも送られていないため、削除しても配信は変わりません。")
        static let deleteAffects = Words("这些简报将不再发到它：{names}。", "These digests will no longer go to it: {names}.", "これらのダイジェストは送られなくなります：{names}。")
        static let deleteNoTarget = Words("其中 {names} 将没有机器人可发（无目标），需要在「简报」里重新选。", "{names} will have no bot left to send to; choose another under Digests.", "{names} は送り先がなくなります（送信先なし）。「ダイジェスト」で選び直してください。")
        static let deleteAccounts = Words("单独发的 X 账号也会受影响：{names}。", "Separately sent X accounts are affected too: {names}.", "個別配信の X アカウントも影響を受けます：{names}。")
        static let needsPairing = Words("还没和你的 Telegram 账号配对。生成配对码，在 Telegram 里发给它。", "Not paired with your Telegram account yet. Make a pairing code and send it to the bot in Telegram.", "まだ Telegram アカウントとペアリングしていません。ペアリングコードを作り、Telegram でボットに送ってください。")
        static let unpairedNote = Words("已解除配对。重新配对后才会收到简报。", "Unpaired. It receives digests again once paired.", "ペアリングを解除しました。再びペアリングするとダイジェストが届きます。")
        static let makeCode = Words("生成配对码", "Make Pairing Code", "ペアリングコードを作成")
        static let pairAgain = Words("重新配对", "Pair Again", "再ペアリング")
        static let adultAllowed = Words("允许接收成人内容", "Allow adult content", "成人向けコンテンツを受け取る")
        static let adultOnNote = Words("AV 产业、X 成人博主只能发到开了这项的机器人。", "AV industry and adult X creators go only to bots with this on.", "AV 業界と成人向け X 投稿者は、これがオンのボットにだけ送られます。")
        static let adultOffNote = Words("关闭时，成人简报不能选这个机器人。", "While off, adult digests cannot choose this bot.", "オフの間、成人向けダイジェストはこのボットを選べません。")
        static let adultOffTitle = Words("{name} 不再接收成人内容？", "Stop adult content for {name}?", "{name} で成人向けコンテンツを受け取らないようにしますか？")
        static let adultOffBody = Words("这些成人简报会不再发到它：{names}。", "These adult digests will no longer go to it: {names}.", "これらの成人向けダイジェストは送られなくなります：{names}。")
        static let adultOffButton = Words("不再接收", "Stop Adult Content", "受け取らない")
        static let modelsTitle = Words("模型", "Models", "モデル")
        static let modelsNote = Words("普通内容和成人内容分开用不同的模型；一边出错不会拿另一边兜底。", "Ordinary and adult content use separate models; one never stands in for the other.", "一般と成人向けは別のモデルを使い、片方の失敗をもう片方で補うことはありません。")
        static let normalGroup = Words("普通内容", "Ordinary content", "一般コンテンツ")
        static let adultGroup = Words("成人内容", "Adult content", "成人向けコンテンツ")
        static let backupPrefix = Words("备用：", "Backup: ", "予備：")
        static let xiaomi = Words("小米", "Xiaomi", "Xiaomi（小米）")
        static let capText = Words("文字", "Text", "テキスト")
        static let capVision = Words("视觉", "Vision", "画像認識")
        static let capImage = Words("生图", "Images", "画像生成")
        static let capSpeech = Words("转写", "Transcription", "文字起こし")
        static let verifiedAt = Words("验证于{when}", "checked {when}", "{when} に確認")
        static let statusUsable = Words("可用", "Working", "利用可")
        static let statusNoKey = Words("未填 Key", "No key", "キー未入力")
        static let statusUntested = Words("还没测试", "Not checked yet", "未確認")
        static let statusKeyInvalid = Words("Key 无效", "Key rejected", "キーが無効")
        static let statusUnavailable = Words("暂时不可用", "Temporarily unavailable", "一時的に利用不可")
        static let statusCooldown = Words("暂停使用到 {time}", "Paused until {time}", "{time} まで休止")
        static let statusBudget = Words("本月预算不够", "Over this month's budget", "今月の予算不足")
        static let statusUncheckable = Words("暂不能测试", "Cannot be checked", "確認できません")
        static let statusFailed = Words("未通过", "Check failed", "確認できず")
        static let statusKeychain = Words("读不到 Key", "Key unreadable", "キーを読めません")
        static let statusSaved = Words("已填 Key", "Key saved", "キー保存済み")
        static let backupOptional = Words("可选。主模型出错时接手，没填就跳过那一期。", "Optional. Takes over when the main model fails; without it that edition is skipped.", "任意。メインモデルが失敗したときに引き継ぎます。なければその回はスキップします。")
        static let primaryNeedsKey = Words("填入 Key 后才能写简报。", "Digests are written only once this key is entered.", "このキーを入力するとダイジェストを作成できます。")
        static let rejected401 = Words("Key 被拒绝（401）。请到 {provider} 控制台确认 Key 没有过期，再重新填入。", "The key was rejected (401). Check in the {provider} console that it has not expired, then enter it again.", "キーが拒否されました（401）。{provider} のコンソールで期限切れでないか確認し、もう一度入力してください。")
        static let rejected403 = Words("Key 没有使用这个模型的权限（403）。请到 {provider} 控制台检查权限，再重新填入。", "The key may not use this model (403). Check its permissions in the {provider} console, then enter it again.", "このキーにはこのモデルの権限がありません（403）。{provider} のコンソールで権限を確認し、もう一度入力してください。")
        static let rejectedFormat = Words("这个 Key 的格式不对。复制完整 Key 再重新填入。", "This key is not in a valid form. Copy the full key and enter it again.", "キーの形式が正しくありません。完全なキーをコピーして入力し直してください。")
        static let rateLimited = Words("{provider} 说请求太频繁（429）。稍等一分钟再试。", "{provider} says there are too many requests (429). Wait a minute, then check again.", "{provider} からリクエストが多すぎると返されました（429）。1 分ほど待って再確認してください。")
        static let quotaExhausted = Words("{provider} 账户的额度用完了（429）。充值后再测一次。", "The {provider} account is out of credit (429). Add credit, then check again.", "{provider} アカウントの残高がありません（429）。チャージしてから再確認してください。")
        static let unreachable = Words("连不上 {provider}。检查网络后再测一次。", "Could not reach {provider}. Check the network, then check again.", "{provider} に接続できませんでした。ネットワークを確認してから再確認してください。")
        static let providerError = Words("{provider} 出错了。稍后再测一次。", "{provider} had an error. Check again later.", "{provider} でエラーが起きました。あとで再確認してください。")
        static let noReply = Words("{provider} 没有及时回应（等了 90 秒）。这次调用可能已经扣费，确认后再试一次。", "{provider} did not answer in time (90 seconds). The call may have been charged; confirm before trying again.", "{provider} が時間内に応答しませんでした（90 秒）。課金された可能性があるため、確認してから再試行してください。")
        static let interrupted = Words("测试被中断了，可能已经扣费。确认后再试一次。", "The check was interrupted and may have been charged. Confirm before trying again.", "確認が中断され、課金された可能性があります。確認してから再試行してください。")
        static let cooldownNote = Words("连续失败 {count} 次，{time} 后自动恢复。", "Failed {count} times in a row; resumes by itself at {time}.", "{count} 回続けて失敗しました。{time} に自動で再開します。")
        static let enterKey = Words("填入 Key", "Enter Key", "キーを入力")
        static let replaceKey = Words("更换 Key", "Replace Key", "キーを変更")
        static let reenterKey = Words("重新填入", "Enter Again", "入力し直す")
        static let checkAndRetry = Words("检查并重试", "Check and Retry", "確認して再試行")
        static let retryTitle = Words("再测一次？", "Check again?", "もう一度確認しますか？")
        static let retryBody = Words("上一次可能已经扣费，再测一次可能再扣一次（最多 $0.01）。", "The last check may have been charged; checking again may charge once more (up to $0.01).", "前回の確認は課金された可能性があり、もう一度確認するとさらに課金されることがあります（最大 $0.01）。")
        static let keyFor = Words("{model} 的 Key", "Key for {model}", "{model} のキー")
        static let keySaveNote = Words("保存后会自动发一条很短的测试消息，看 Key 能不能用。", "Saving sends one very short test request to see whether the key works.", "保存すると、キーが使えるか短いテストを 1 回送ります。")
        static let extrasTitle = Words("附加能力：AI 报纸生图 · 语音转写 · 自定义 API 地址", "Extras: AI newspaper images · voice transcription · custom API address", "追加機能：AI 新聞画像 · 音声の文字起こし · カスタム API アドレス")
        static let extrasNote = Words("开启某项附加输出时，NewsPaw 会在那时验证对应能力，不需要提前逐项测试。", "When you turn an extra on, NewsPaw checks that capability then; nothing needs checking in advance.", "追加機能をオンにしたときに NewsPaw がその機能を確認します。事前の確認は不要です。")
        static let newspaper = Words("AI 报纸生图", "AI newspaper images", "AI 新聞画像")
        static let newspaperNote = Words("把一期简报排成报纸图片；生图费用另计。", "Lays out an edition as a newspaper image; image generation costs extra.", "ダイジェストを新聞風の画像にします。画像生成の費用は別にかかります。")
        static let transcription = Words("语音转写", "Voice transcription", "音声の文字起こし")
        static let transcriptionNote = Words("在 Telegram 里发给机器人的语音会先转成文字。", "Voice messages you send the bot in Telegram are turned into text first.", "Telegram でボットに送った音声メッセージを先に文字にします。")
        static let useModel = Words("使用", "Use", "使用モデル")
        static let off = Words("已关闭", "Off", "オフ")
        static let checkingCapability = Words("等待检查", "Waiting for check", "確認待ち")
        static let needsOpenAI = Words("需要一个使用 OpenAI 官方地址（api.openai.com）的普通内容模型；可以在下面的「自定义 API 地址」里改。", "Needs an ordinary-content model on OpenAI's own address (api.openai.com); change one under Custom API address below.", "OpenAI 公式アドレス（api.openai.com）を使う一般向けモデルが必要です。下の「カスタム API アドレス」で変更できます。")
        static let endpoint = Words("自定义 API 地址", "Custom API address", "カスタム API アドレス")
        static let endpointNote = Words("兼容 OpenAI 的地址和模型 ID。保存后会用已保存的 Key 再测一次。", "An OpenAI-compatible address and model ID. Saving checks the saved key again.", "OpenAI 互換のアドレスとモデル ID。保存すると保存済みのキーで再確認します。")
        static let spendingTitle = Words("费用", "Spending", "費用")
        static let monthly = Words("每月最多花", "Monthly limit", "毎月の上限")
        static let monthlyNote = Words("到上限后停发并在概览里提醒；留空表示不限。", "At the limit deliveries stop and the overview tells you; leave empty for no limit.", "上限に達すると配信を止めて概要でお知らせします。空欄なら上限なし。")
        static let perMonth = Words("/ 月", "/ month", "/ 月")
        static let noLimit = Words("不限", "No limit", "上限なし")
        static let usedLine = Words("本月已用 {amount}", "Used this month {amount}", "今月の使用額 {amount}")
        static let since = Words("{date} 起", "Since {date}", "{date} から")
        static let dailyReads = Words("X 每天最多读取", "X reads per day", "X の 1 日の読み取り上限")
        static let dailyNote = Words("普通和成人账号合计；今天已读 {count} 条。", "Ordinary and adult accounts together; {count} read today.", "一般と成人向けアカウントの合計。今日は {count} 件読み取りました。")
        static let perDay = Words("条 / 天", "reads / day", "件 / 日")
        static let otherLimits = Words("其他上限", "Other limits", "その他の上限")
        static let imageLimit = Words("生图每月最多 {amount}", "Images up to {amount} a month", "画像生成は毎月 {amount} まで")
        static let providerLimit = Words("{provider} 每月最多 {amount}", "{provider} up to {amount} a month", "{provider} は毎月 {amount} まで")
        static let normalReadsLimit = Words("X 普通账号每天最多 {count} 条", "Ordinary X accounts up to {count} reads a day", "一般の X アカウントは 1 日 {count} 件まで")
        static let adultReadsLimit = Words("X 成人账号每天最多 {count} 条", "Adult X accounts up to {count} reads a day", "成人向け X アカウントは 1 日 {count} 件まで")
        static let accountLimit = Words("{account} 每天最多 {count} 条", "{account} up to {count} reads a day", "{account} は 1 日 {count} 件まで")
        static let readToday = Words("今天已读 {count} 条", "{count} read today", "今日 {count} 件")
        static let limitReached = Words("已到上限", "Limit reached", "上限に達しました")
        static let clear = Words("清除", "Clear", "解除")
        static let pricingNote = Words("用量按模型返回的 token 数计价；没有价格信息的模型会标为「未计价」，不会因此停发。", "Usage is priced from the tokens each model reports; a model without a price is marked Unpriced and never stops deliveries.", "使用量はモデルが返すトークン数で計算します。価格情報のないモデルは「未計価」と表示され、それを理由に配信は止まりません。")
        static let unpricedCount = Words("本月有 {count} 次调用未计价。", "{count} calls this month are unpriced.", "今月は {count} 回の呼び出しが未計価です。")
        static let opText = Words("文字", "Text", "テキスト")
        static let opImage = Words("报纸", "Newspaper", "新聞")
        static let opVision = Words("看图", "Images read", "画像認識")
        static let opSpeech = Words("转写", "Transcription", "文字起こし")
        static let opSearch = Words("搜索", "Search", "検索")
        static let opOther = Words("其他", "Other", "その他")
        static let xTitle = Words("X 数据连接", "X data connection", "X データ接続")
        static let xReadsFine = Words("读取账号正常", "Reading accounts works", "アカウントを読み取れています")
        static let xNeedsKey = Words("填入后才能读取 X 账号。", "X accounts can be read once a key is entered.", "キーを入力すると X アカウントを読み取れます。")
        static let xUnused = Words("添加或验证 X 账号时会用到它。", "Used when X accounts are added or checked.", "X アカウントの追加や確認で使います。")
        static let xRejected = Words("X 拒绝了这个 Key（401）。到 X 开发者后台确认后重新填入。", "X rejected this key (401). Check it in the X developer portal, then enter it again.", "X がこのキーを拒否しました（401）。X の開発者ポータルで確認してから入力し直してください。")
        static let xForbidden = Words("这个 Key 没有读取权限（403）。到 X 开发者后台检查权限后重新填入。", "This key may not read accounts (403). Check its permissions in the X developer portal, then enter it again.", "このキーには読み取り権限がありません（403）。X の開発者ポータルで権限を確認してから入力し直してください。")
        static let xKeyNote = Words("Key 只存在这台 Mac 的钥匙串里。", "The key is kept only in this Mac's keychain.", "キーはこの Mac のキーチェーンにだけ保存されます。")

        static let all: [Words] = [
            intro, todayAt, yesterdayAt, save, saving, botsTitle, addBot, noBots, receives, receivesNone, rename,
            statusUnverified, statusWaiting, statusPaired, statusPaused, statusUnpaired, statusProblem, sendTest,
            sending, testSent, testUnknown, checkResult, testStillUnknown, testNotSent, sendAgain, more, pause, resume,
            replaceToken, unpair, delete, unpairTitle, unpairBody, unpairButton, deleteTitle, deleteButton,
            deleteNone, deleteAffects, deleteNoTarget, deleteAccounts, needsPairing, unpairedNote, makeCode,
            pairAgain, adultAllowed, adultOnNote, adultOffNote, adultOffTitle, adultOffBody, adultOffButton,
            modelsTitle, modelsNote, normalGroup, adultGroup, backupPrefix, xiaomi, capText, capVision, capImage,
            capSpeech, verifiedAt, statusUsable, statusNoKey, statusUntested, statusKeyInvalid, statusUnavailable,
            statusCooldown, statusBudget, statusUncheckable, statusFailed, statusKeychain, statusSaved,
            backupOptional, primaryNeedsKey, rejected401, rejected403, rejectedFormat, rateLimited, quotaExhausted,
            unreachable, providerError, noReply, interrupted, cooldownNote, enterKey, replaceKey, reenterKey,
            checkAndRetry, retryTitle, retryBody, keyFor, keySaveNote, extrasTitle, extrasNote, newspaper,
            newspaperNote, transcription, transcriptionNote, useModel, off, checkingCapability, needsOpenAI, endpoint,
            endpointNote, spendingTitle, monthly, monthlyNote, perMonth, noLimit, usedLine, since, dailyReads,
            dailyNote, perDay, otherLimits, imageLimit, providerLimit, normalReadsLimit, adultReadsLimit,
            accountLimit, readToday, limitReached, clear, pricingNote, unpricedCount, opText, opImage, opVision,
            opSpeech, opSearch, opOther, xTitle, xReadsFine, xNeedsKey, xUnused, xRejected, xForbidden, xKeyNote,
        ]
    }

    /// The X accounts page (interaction-spec §7).
    enum XAccounts {
        static let intro = Words("只跟踪你指定的账号。每个账号只需决定一件事：单独发，还是并入每天的汇总。", "Only the accounts you name are followed. Each needs one choice: sent alone, or in the daily digest.", "指定したアカウントだけを追います。各アカウントで決めるのは 1 つだけ：単独で送るか、毎日のまとめに入れるか。")
        static let kind = Words("账号类别", "Kind of account", "アカウントの種類")
        static let normalTab = Words("普通账号 · {count}", "Ordinary · {count}", "一般 · {count}")
        static let adultTab = Words("成人博主 · {count}", "Adult creators · {count}", "成人向け · {count}")
        static let normalKind = Words("普通账号", "Ordinary", "一般")
        static let adultKind = Words("成人博主", "Adult creators", "成人向け")
        static let needsXKey = Words("还没有填 X API Key。添加账号前先在「接入」填入。", "No X API key yet. Enter one in Connect before adding accounts.", "X API キーがまだありません。アカウントを追加する前に「接続」で入力してください。")
        static let needsAdultKey = Words("成人博主需要成人模型 Key。列表可以浏览，添加要先在「接入」填入。", "Adult creators need an adult model key. You can browse the list; add one in Connect before adding accounts.", "成人向けには成人向けモデルのキーが必要です。一覧は見られますが、追加する前に「接続」で入力してください。")
        static let goConnect = Words("去接入", "Open Connect", "接続を開く")
        static let add = Words("添加", "Add", "追加")
        static let addPlaceholder = Words("@用户名，或粘贴 X List 链接", "@username, or paste an X List link", "@ユーザー名、または X リストのリンク")
        static let addNote = Words("会读一次账号资料（1 次读取），确认账号存在、是否受保护；List 会读取资料和成员（最多 5 次读取）。", "Reads the account's profile once (1 read) to confirm it exists and whether it is protected; a List reads its details and members (up to 5 reads).", "アカウント情報を 1 回読み取り（1 回）、存在するか・非公開かを確認します。リストは情報とメンバーを読み取ります（最大 5 回）。")
        static let reading = Words("正在读取…", "Reading…", "読み取り中…")
        static let stillGoing = Words("仍在进行，可以先做别的。", "Still going; you can do something else meanwhile.", "まだ続いています。ほかの作業をしていて構いません。")
        static let added = Words("已加入 {handle}，并入汇总。", "{handle} was added to the digest.", "{handle} をまとめに追加しました。")
        static let protectedResult = Words("{handle} 设了保护，读不到它的帖子。", "{handle} is protected; its posts cannot be read.", "{handle} は非公開のため、投稿を読み取れません。")
        static let keepAnyway = Words("仍然添加", "Add Anyway", "それでも追加")
        static let discard = Words("放弃", "Discard", "やめる")
        static let missingResult = Words("X 上找不到 {handle}，账号不存在或已停用。", "{handle} was not found on X; it does not exist or was suspended.", "X に {handle} が見つかりません。存在しないか停止されています。")
        static let alreadyListed = Words("{handle} 已经在列表里了。", "{handle} is already in the list.", "{handle} はすでに一覧にあります。")
        static let inOtherKind = Words("{name} 已经在「{kind}」里了；要换类请到那边用「改为…」。", "{name} is already under \u{201C}{kind}\u{201D}; to switch, use \u{201C}Move to…\u{201D} there.", "{name} はすでに「{kind}」にあります。切り替えるにはそちらで「…へ移す」を使ってください。")
        static let listResult = Words("「{name}」· {count} 个成员，默认整体并入汇总；新成员会先问你是哪一类。", "\u{201C}{name}\u{201D} · {count} members, all in the digest by default; new members are asked about first.", "「{name}」· メンバー {count} 人。既定ではまとめて追加します。新しいメンバーは先に確認します。")
        static let emptyNormal = Words("还没有普通账号。在上面输入 @用户名 添加。", "No ordinary accounts yet. Type an @username above to add one.", "一般アカウントはまだありません。上に @ユーザー名 を入力して追加してください。")
        static let emptyAdult = Words("还没有成人博主。在上面输入 @用户名 添加。", "No adult creators yet. Type an @username above to add one.", "成人向けアカウントはまだありません。上に @ユーザー名 を入力して追加してください。")
        static let stateReadable = Words("可读", "Readable", "読み取り可")
        static let stateProtected = Words("读不到", "Can't read", "読み取れません")
        static let stateGone = Words("账号不存在或已停用", "Not found or suspended", "存在しないか停止中")
        static let stateRecheck = Words("需要重新验证", "Needs a new check", "再確認が必要")
        static let stateNoPermission = Words("X Key 没有读取权限", "X key may not read", "X キーに読み取り権限なし")
        static let stateKeyRejected = Words("X Key 无效", "X key rejected", "X キーが無効")
        static let stateUnverified = Words("待验证", "Not checked", "未確認")
        static let protectedNote = Words("这个账号设了保护，NewsPaw 读不到它的帖子。", "This account is protected; NewsPaw cannot read its posts.", "このアカウントは非公開のため、NewsPaw は投稿を読み取れません。")
        static let goneNote = Words("X 上已经找不到这个账号。", "This account can no longer be found on X.", "このアカウントは X で見つからなくなりました。")
        static let lastRead = Words("{when} 读到", "read {when}", "{when} に読み取り")
        static let newToday = Words("今天 {count} 条新帖", "{count} new today", "今日の新着 {count} 件")
        static let notReadYet = Words("还没读过", "not read yet", "未読み取り")
        static let readAgain = Words("重新验证", "Check Again", "再確認")
        static let alone = Words("单独发", "Alone", "単独で送る")
        static let aloneAt = Words("单独发 · {time}", "Alone · {time}", "単独 · {time}")
        static let inDigest = Words("并入汇总", "In Digest", "まとめに入れる")
        static let sendChoice = Words("单独发或并入汇总", "Send alone or in the digest", "単独で送るか、まとめに入れるか")
        static let postTypes = Words("帖子类型", "Post Types", "投稿の種類")
        static let typeOriginal = Words("原帖", "Posts", "オリジナル")
        static let typeQuote = Words("引用", "Quotes", "引用")
        static let typeReply = Words("回复", "Replies", "返信")
        static let typeRepost = Words("转帖", "Reposts", "リポスト")
        static let readAgainMenu = Words("重新读取账号资料（1 次读取）", "Read Profile Again (1 Read)", "アカウント情報を再読み取り（1 回）")
        static let moveMenu = Words("改为{kind}…", "Move to {kind}…", "{kind}へ移す…")
        static let removeMenu = Words("移除…", "Remove…", "削除…")
        static let remove = Words("移除", "Remove", "削除")
        static let moreFor = Words("{handle} 的更多操作", "More for {handle}", "{handle} のその他の操作")
        static let removeTitle = Words("移除 {handle}？", "Remove {handle}?", "{handle} を削除しますか？")
        static let removeBody = Words("它不会再被读取，也不会出现在汇总里。", "It will no longer be read or appear in the digest.", "今後は読み取られず、まとめにも入りません。")
        static let removeAlone = Words("它每天 {time} 的单独发也会停止（{bots}）。", "Its own edition at {time} each day stops too ({bots}).", "毎日 {time} の単独配信も止まります（{bots}）。")
        static let rulesDropped = Words("提到它的 {count} 条大事件提醒规则会一起删除。", "Its {count} alert rules are removed with it.", "このアカウントの通知ルール {count} 件も削除されます。")
        static let moveTitle = Words("把 {handle} 改为{kind}？", "Move {handle} to {kind}?", "{handle} を{kind}へ移しますか？")
        static let moveButton = Words("改过去", "Move", "移す")
        static let moveLeavesDigest = Words("它会离开{kind}汇总（{bots}）。", "It leaves the {kind} digest ({bots}).", "{kind}のまとめから外れます（{bots}）。")
        static let moveStopsAlone = Words("它的单独发会停止（{bots}），时间、机器人和样式会清除。", "Its own edition stops ({bots}); its time, Bots and style are cleared.", "単独配信は止まり（{bots}）、時刻・ボット・スタイルは消去されます。")
        static let moveResetsTypes = Words("帖子类型会恢复为原帖 + 引用。", "Post types go back to posts + quotes.", "投稿の種類はオリジナル + 引用に戻ります。")
        static let moveKeepsPosts = Words("已读到的 {count} 条帖子留在{kind}里，不会带过去。", "The {count} posts already read stay with {kind} and do not move.", "読み取り済みの投稿 {count} 件は{kind}に残り、移りません。")
        static let movePending = Words("还有 {count} 期正在准备或等待发送的简报包含它。", "{count} editions being prepared or waiting to send include it.", "準備中または送信待ちのダイジェスト {count} 回にこのアカウントが含まれます。")
        static let moveJoins = Words("改完后它会并入{kind}汇总。", "Afterwards it joins the {kind} digest.", "移した後は{kind}のまとめに入ります。")
        static let aloneTitle = Words("单独发 {handle}", "Send {handle} alone", "{handle} を単独で送る")
        static let aloneNote = Words("每天这个时间单独发一期，只含这个账号的帖子。", "One edition at this time every day, with only this account's posts.", "毎日この時刻に、このアカウントの投稿だけで 1 回送ります。")
        static let botsInherit = Words("默认和汇总发到同一处。", "By default it goes where the digest goes.", "既定ではまとめと同じ送信先です。")
        static let noBot = Words("还没有已配对的机器人。", "No paired Bot yet.", "ペアリング済みのボットがありません。")
        static let noAdultBot = Words("还没有允许成人内容的已配对机器人。", "No paired Bot allows adult content yet.", "成人向けを許可したペアリング済みボットがありません。")
        static let chooseBot = Words("至少选一个机器人。", "Choose at least one Bot.", "ボットを 1 つ以上選んでください。")
        static let memberCount = Words("{count} 个成员", "{count} members", "メンバー {count} 人")
        static let listNote = Words("成员全部并入汇总 · 新加入的成员会先问你是不是普通内容", "All members are in the digest · new members are asked about first", "メンバーは全員まとめに入ります · 新メンバーは一般か先に確認します")
        static let listNoteAdult = Words("成员全部并入成人博主汇总 · 新加入的成员也按成人内容处理", "All members are in the adult digest · new members count as adult too", "メンバーは全員成人向けのまとめに入ります · 新メンバーも成人向けとして扱います")
        static let pendingMembers = Words("{count} 个新成员待确认", "{count} new members to confirm", "新メンバー {count} 人が確認待ち")
        static let view = Words("查看", "View", "表示")
        static let readMembers = Words("重新读取成员（最多 5 次读取）", "Read Members Again (Up to 5 Reads)", "メンバーを再読み取り（最大 5 回）")
        static let listRead = Words("成员已读取", "Members read", "メンバー読み取り済み")
        static let listUnread = Words("还没读取成员", "Members not read yet", "メンバー未読み取り")
        static let listPrivate = Words("私密 List，读不到", "Private List; can't read", "非公開リストのため読み取れません")
        static let listIncomplete = Words("成员没读完整", "Members incomplete", "メンバーの読み取りが不完全")
        static let notInDigest = Words("还没并入汇总", "not in the digest yet", "まだまとめに入っていません")
        static let joinTitle = Words("把 {handle} 并入汇总？", "Put {handle} in the digest?", "{handle} をまとめに入れますか？")
        static let membersOutside = Words("{count} 个成员还没并入汇总", "{count} members not in the digest", "まとめに入っていないメンバー {count} 人")
        static let listNoteOutside = Words("成员要并入汇总后才会被读取", "Members are read once they are in the digest", "メンバーはまとめに入ると読み取られます")
        static let listNotePending = Words("有新成员等你选是哪一类，选好后并入汇总", "New members wait for you to choose their kind; then they join the digest", "新メンバーの種類を選ぶと、まとめに入ります")
        static let draftLeft = Words("刚建的账号条目没能删掉。", "The entry just created could not be removed.", "作成したばかりの項目を削除できませんでした。")
        static let rulesLeft = Words("账号已改好，但它的提醒规则没能一起删除。", "The account was changed, but its alert rules could not be removed with it.", "アカウントは変更しましたが、その通知ルールを一緒に削除できませんでした。")
        static let coveragePartial = Words("上次只读到一部分帖子（到了每次读取的上限）", "Only part of the posts were read last time (the per-read limit was reached)", "前回は投稿の一部しか読み取れませんでした（1 回の上限に達しました）")
        static let coverageGap = Words("上次读取中间有缺口，可能漏了帖子", "The last read has a gap; some posts may be missing", "前回の読み取りに抜けがあり、投稿が欠けている可能性があります")
        static let coverageUnfinished = Words("上次没读完，下次会接着读", "The last read did not finish; the next one continues", "前回の読み取りは終わっていません。次回続きを読みます")
        static let membersTitle = Words("「{name}」的新成员", "New members of \u{201C}{name}\u{201D}", "「{name}」の新メンバー")
        static let membersNote = Words("选普通或成人后并入那一类的汇总；忽略的成员不会被读取。", "Ordinary or adult adds a member to that digest; ignored members are not read.", "一般か成人向けを選ぶとそのまとめに入ります。無視したメンバーは読み取りません。")
        static let ignore = Words("忽略", "Ignore", "無視")
        static let membersDone = Words("都处理好了。", "All set.", "すべて確認しました。")
        static let waitingNote = Words("还没决定是普通账号还是成人博主，决定后并入那一类的汇总。", "Not yet ordinary or adult; once chosen it joins that digest.", "一般か成人向けかがまだ決まっていません。選ぶとそのまとめに入ります。")
        static let normalDigest = Words("普通账号汇总", "Ordinary digest", "一般のまとめ")
        static let adultDigest = Words("成人博主汇总", "Adult digest", "成人向けのまとめ")
        static let editInDigests = Words("在简报里改", "Edit in Digests", "ダイジェストで編集")
        static let noDigest = Words("没有这一类的 X 简报。", "There is no X digest of this kind.", "この種類の X ダイジェストはありません。")
        static let aggregateCount = Words("{count} 个并入汇总的账号", "{count} accounts in the digest", "まとめに入るアカウント {count} 件")
        static let separateCount = Words("{count} 个单独发", "{count} sent alone", "単独 {count} 件")
        static let listCount = Words("{count} 个 List", "{count} Lists", "リスト {count} 件")
        static let readsTitle = Words("每天最多读取", "Reads per day", "1 日の読み取り上限")
        static let readsLine = Words("条 / 天 · 今天已读 {count}", "reads / day · {count} read today", "件 / 日 · 今日 {count} 件読み取り")
        static let readsNote = Words("普通和成人账号合计。想分开限额可以在「高级」里设。", "Ordinary and adult accounts together. Separate limits are under Advanced.", "一般と成人向けの合計です。別々の上限は「詳細」で設定できます。")
        static let advancedTitle = Words("高级：大事件即时提醒 · 视频内容检查 · 普通 / 成人各自限额", "Advanced: event alerts · video checks · separate limits", "詳細：重要イベント通知 · 動画の確認 · 種類別の上限")
        static let advancedNote = Words("默认都关闭，不会增加读取量或费用。", "All off by default; they add no reads or costs until turned on.", "既定ではすべてオフで、読み取りや費用は増えません。")
        static let alerts = Words("大事件即时提醒", "Major event alerts", "重要イベントの即時通知")
        static let alertsNote = Words("汇总里出现这些关键词时立刻提醒你，每天最多 {count} 条；普通和成人共用这个开关。", "Alerts you as soon as these phrases show up, up to {count} a day; one switch for ordinary and adult.", "まとめにこれらの語句が出たらすぐ通知します（1 日最大 {count} 件）。一般と成人向けで共通のスイッチです。")
        static let alertsNeedRule = Words("先加一条规则。", "Add a rule first.", "先にルールを追加してください。")
        static let rulePlaceholder = Words("关键词，例如：发布会", "Phrase, e.g. launch event", "語句（例：発表会）")
        static let ruleScope = Words("范围", "Where", "範囲")
        static let ruleDigest = Words("整个汇总", "Whole digest", "まとめ全体")
        static let addRule = Words("加一条规则", "Add Rule", "ルールを追加")
        static let removeRule = Words("删除规则", "Remove rule", "ルールを削除")
        static let video = Words("视频内容检查", "Video checks", "動画の確認")
        static let videoNote = Words("对已发出的普通 X 汇总里的视频，你点「检查」时看画面、转写声音。", "For videos in sent ordinary X digests: look at frames and transcribe audio when you choose Check.", "送信済みの一般 X まとめの動画について、「確認」を押したときに映像を見て音声を文字起こしします。")
        static let videoNeedsModels = Words("需要一个能看图、一个能转写语音的普通模型，先在「接入 › 附加能力」开启。", "Needs ordinary models that can see images and transcribe voice; turn them on in Connect › Extras.", "画像認識と音声の文字起こしができる一般モデルが必要です。「接続 › 追加機能」でオンにしてください。")
        static let videoBudget = Words("每天最多花", "Spend at most", "1 日の上限")
        static let perDayMoney = Words("/ 天", "/ day", "/ 日")
        static let noVideos = Words("最近发出的汇总里没有可以检查的视频。", "No videos to check in recently sent digests.", "最近送ったまとめに確認できる動画はありません。")
        static let inspect = Words("检查", "Check", "確認")
        static let inspectTitle = Words("检查这个视频？", "Check this video?", "この動画を確認しますか？")
        static let inspectBody = Words("会读一次 X，并调用看图和转写模型，可能产生费用（计入每天的上限）。", "Reads X once and calls the vision and transcription models; this may cost money (within the daily limit).", "X を 1 回読み取り、画像認識と文字起こしのモデルを呼び出します。費用がかかる場合があります（1 日の上限内）。")
        static let viewResult = Words("看结果", "View Result", "結果を見る")
        static let videoDone = Words("检查完成", "Check complete", "確認完了")
        static let videoPartial = Words("只检查了一部分", "Partly checked", "一部のみ確認")
        static let transcript = Words("声音转写（原文）", "Audio transcript (original)", "音声の文字起こし（原文）")
        static let partitionLimits = Words("普通 / 成人各自限额", "Separate limits", "種類別の上限")
        static let partitionLimitsNote = Words("在每天总上限之内，再分别限制两类账号的读取；留空表示不单独限制。", "Within the daily total, limit each kind separately; empty means no separate limit.", "1 日の合計の範囲内で種類ごとに制限します。空欄は個別の上限なしです。")
        static let partitionLimitLabel = Words("{kind}每天最多读取", "{kind} reads per day", "{kind}の 1 日の読み取り上限")

        static let all: [Words] = [
            intro, kind, normalTab, adultTab, normalKind, adultKind, needsXKey, needsAdultKey, goConnect, add, addPlaceholder,
            addNote, reading, stillGoing, added, protectedResult, keepAnyway, discard, missingResult, alreadyListed, inOtherKind,
            listResult, emptyNormal, emptyAdult, stateReadable, stateProtected, stateGone, stateRecheck, stateNoPermission,
            stateKeyRejected, stateUnverified, protectedNote, goneNote, lastRead, newToday, notReadYet, readAgain, alone, aloneAt,
            inDigest, sendChoice, postTypes, typeOriginal, typeQuote, typeReply, typeRepost, readAgainMenu, moveMenu, removeMenu,
            remove, moreFor, removeTitle, removeBody, removeAlone, rulesDropped, moveTitle, moveButton, moveLeavesDigest,
            moveStopsAlone, moveResetsTypes, moveKeepsPosts, movePending, moveJoins, aloneTitle, aloneNote, botsInherit, noBot,
            noAdultBot, chooseBot, memberCount, listNote, listNoteAdult, pendingMembers, view, readMembers, listRead, listUnread,
            listPrivate, listIncomplete, membersTitle, membersNote, ignore, membersDone, waitingNote, normalDigest, adultDigest,
            editInDigests, noDigest, aggregateCount, separateCount, listCount, readsTitle, readsLine, readsNote, advancedTitle,
            advancedNote, alerts, alertsNote, alertsNeedRule, rulePlaceholder, ruleScope, ruleDigest, addRule, removeRule, video,
            videoNote, videoNeedsModels, videoBudget, perDayMoney, noVideos, inspect, inspectTitle, inspectBody, viewResult,
            videoDone, videoPartial, transcript, partitionLimits, partitionLimitsNote, partitionLimitLabel,
            notInDigest, joinTitle, membersOutside, listNoteOutside, listNotePending, draftLeft, rulesLeft,
            coveragePartial, coverageGap, coverageUnfinished, listNotePending,
        ]
    }

    enum Settings {
        static let intro = Words("语言、后台和数据。排障工具都在最下面的「高级」里。", "Language, the backend and your data. Troubleshooting tools are under Advanced at the bottom.", "言語、バックエンド、データ。トラブル対応のツールはいちばん下の「詳細」にあります。")
        static let language = Words("语言", "Language", "言語")
        static let uiLanguage = Words("界面语言", "Interface language", "表示言語")
        static let uiLanguageNote = Words("只影响这个窗口和 Telegram 里的管理回复。", "Affects only this window and management replies in Telegram.", "このウインドウと Telegram の管理用の返信だけに使います。")
        static let newsLanguage = Words("新闻输出语言", "News language", "ニュースの言語")
        static let newsLanguageNote = Words("所有简报的标题和摘要。改了之后，还没发出的那几期会按新语言重新生成。", "Titles and summaries of every digest. After a change, editions not yet sent are written again in the new language.", "すべてのダイジェストの見出しと要約に使います。変更すると、まだ送っていない回は新しい言語で作り直します。")
        static let newsLanguageOffline = Words("后台运行后才能修改。", "Can be changed once the backend is running.", "バックエンドが動いているときに変更できます。")

        static let backend = Words("后台", "Backend", "バックエンド")
        static let status = Words("状态", "Status", "状態")
        static let running = Words("运行中", "Running", "稼働中")
        static let notRunning = Words("没有运行", "Not running", "停止中")
        static let started = Words("{when} 启动", "Started {when}", "{when} に起動")
        static let version = Words("版本 {version}", "Version {version}", "バージョン {version}")
        static let restart = Words("重启", "Restart", "再起動")
        static let restartHelp = Words("打开「登录这台 Mac 时自动启动」后才能从这里重启。", "Turn on “Start when you log in to this Mac” to restart from here.", "「この Mac にログインしたときに起動」をオンにするとここから再起動できます。")
        static let stop = Words("停止", "Stop", "停止")
        static let start = Words("启动后台", "Start Backend", "バックエンドを起動")
        static let loginItem = Words("登录这台 Mac 时自动启动", "Start when you log in to this Mac", "この Mac にログインしたときに起動")
        static let loginItemNote = Words("关闭后后台会停止，不再推送，直到你重新打开这个开关。", "Turning this off stops the backend; nothing is delivered until you turn it on again.", "オフにするとバックエンドが止まり、もう一度オンにするまで配信されません。")
        static let loginOffTitle = Words("关闭自动启动？", "Turn off starting at login?", "ログイン時の起動をオフにしますか？")
        static let loginOffBody = Words("后台会立即停止，菜单栏将不再推送，直到你重新打开这个开关。", "The backend stops now and the menu bar delivers nothing until you turn this on again.", "バックエンドはすぐに止まり、もう一度オンにするまでメニューバーから配信されません。")
        static let loginOffButton = Words("关闭并停止后台", "Turn Off and Stop", "オフにして停止")
        static let openLoginItems = Words("打开登录项设置", "Open Login Items Settings", "ログイン項目の設定を開く")
        static let pauseNote = Words("暂停期间不采集、不花钱、不发送；恢复后只补最近一期。菜单栏里也有这个开关。", "While paused nothing is collected, spent or sent; resuming catches up only the latest edition. The menu bar has this switch too.", "一時停止中は収集も支払いも送信もしません。再開すると直近の 1 回だけ追いつきます。メニューバーにも同じスイッチがあります。")

        static let data = Words("数据", "Data", "データ")
        static let storage = Words("存放位置", "Storage location", "保存場所")
        static let showInFinder = Words("在访达中显示", "Show in Finder", "Finder で表示")
        static let backup = Words("设置备份", "Settings backup", "設定のバックアップ")
        static let backupNote = Words("导出不包含任何 Key 和 Token。导入前会先给你看会改什么。", "Exports contain no keys or tokens. Before importing you see what would change.", "書き出しにキーやトークンは含まれません。読み込む前に何が変わるかを確認できます。")
        static let export = Words("导出设置…", "Export Settings…", "設定を書き出す…")
        static let `import` = Words("导入…", "Import…", "読み込む…")
        static let retention = Words("保留抓取记录和日志", "Keep fetch records and logs", "取得記録とログの保存期間")
        static let retentionNote = Words("清理旧数据时只删除早于这个天数的记录；还没发出的简报引用到的记录不会被清。X 帖子正文不按这个天数，超过 24 小时就会清掉。", "Cleaning up removes only records older than this; records an unsent digest uses are kept. X post text is different: it is cleared once older than 24 hours.", "古いデータの整理ではこれより古い記録だけを消します。まだ送っていないダイジェストが使う記録は残します。X の投稿本文はこの設定に関係なく、24 時間を過ぎると消します。")
        static let days = Words("{count} 天", "{count} days", "{count} 日")
        static let saved = Words("已保存到所选文件。", "Saved to the chosen file.", "選んだファイルに保存しました。")
        static let copied = Words("已复制。", "Copied.", "コピーしました。")
        static let imported = Words("已导入。所有简报保持关闭；机器人要重新配对，模型要重新填 Key。", "Imported. Every digest stays off; pair the bots again and enter the model keys again.", "読み込みました。ダイジェストはすべてオフのままです。ボットのペアリングとモデルのキー入力をやり直してください。")

        static let importTitle = Words("导入这些设置？", "Import these settings?", "この設定を読み込みますか？")
        static let importChanges = Words("会改动这些项目：", "These would change:", "次の項目が変わります：")
        static let importNothing = Words("这个文件和当前设置一样，导入不会改动任何项目。", "This file matches the current settings; importing changes nothing.", "このファイルは今の設定と同じで、読み込んでも何も変わりません。")
        static let importAgain = Words("设置刚有变化，下面是重新比较的结果，请再确认一次。", "Something changed meanwhile; this is the new comparison. Please confirm again.", "その間に変更があったため比べ直しました。もう一度確認してください。")
        static let importStaysOff = Words("导入后所有简报保持关闭，推送不会自动开始。", "Every digest stays off after importing; nothing starts sending by itself.", "読み込んだ後もダイジェストはすべてオフで、配信が勝手に始まることはありません。")
        static let importPairing = Words("机器人要重新填 Token 并配对。", "Bots need their token and pairing again.", "ボットはトークンの入力とペアリングをやり直します。")
        static let importKeys = Words("模型的 Key 不在设置文件里，要重新填。", "Model keys are not in the file; enter them again.", "モデルのキーはファイルに含まれないので入力し直します。")
        static let importButton = Words("导入", "Import", "読み込む")
        static let changeUI = Words("界面语言改为 {value}", "Interface language becomes {value}", "表示言語を {value} に変更")
        static let changeNews = Words("新闻输出语言改为 {value}", "News language becomes {value}", "ニュースの言語を {value} に変更")
        static let changeTimezone = Words("时区改为 {value}", "Time zone becomes {value}", "タイムゾーンを {value} に変更")
        static let changeDigests = Words("简报：{names}", "Digests: {names}", "ダイジェスト：{names}")
        static let removeDigests = Words("移除简报：{names}", "Digests removed: {names}", "削除するダイジェスト：{names}")
        static let kindSources = Words("来源", "Sources", "ソース")
        static let kindBots = Words("机器人", "Bots", "ボット")
        static let kindAccounts = Words("X 账号", "X accounts", "X アカウント")
        static let kindModels = Words("模型", "Models", "モデル")
        static let added = Words("新增 {count}", "{count} added", "追加 {count}")
        static let removed = Words("移除 {count}", "{count} removed", "削除 {count}")
        static let changed = Words("改动 {count}", "{count} changed", "変更 {count}")
        static let kindDigestTypes = Words("简报类型", "Digest types", "ダイジェストの種類")
        static let typeLine = Words("{digests}：{parts}", "{digests}: {parts}", "{digests}：{parts}")
        static let typeMoved = Words("改为{partition}", "now {partition}", "{partition}に変更")
        static let typeRenamed = Words("名称改为 {name}", "renamed to {name}", "名前を {name} に変更")
        static let otherChanges = Words("还有其他设置会改动。", "Other settings would change too.", "ほかの設定も変わります。")
        static let collectionLine = Words("{kind}：{parts}", "{kind}: {parts}", "{kind}：{parts}")
        static let omittedLine = Words("有 {count} 项含 Key 或私有地址，没有带过来。", "{count} entries with keys or private addresses were left out.", "キーや非公開アドレスを含む {count} 件は持ち込みません。")

        static let advanced = Words("高级 / 排障", "Advanced / Troubleshooting", "詳細 / トラブル対応")
        static let advancedSummary = Words("诊断信息 · 支持快照 · 备份校验 · 清理旧数据 · 任务与投递记录", "Diagnostics · Support snapshot · Backup check · Clean up · Jobs and deliveries", "診断情報・サポート用スナップショット・バックアップ確認・古いデータの整理・処理と配信の記録")
        static let advancedNote = Words("给开发者看的工具。正常使用不需要打开。", "Tools for developers. Everyday use never needs them.", "開発者向けのツールです。普段は開く必要はありません。")
        static let diagnostics = Words("诊断信息", "Diagnostics", "診断情報")
        static let diagnosticsNote = Words("脱敏的运行状况，不含 Key、名称或链接。", "A redacted summary of how things are running, without keys, names or links.", "キー、名前、リンクを含まない匿名化した稼働状況です。")
        static let copy = Words("复制", "Copy", "コピー")
        static let saveFile = Words("保存…", "Save…", "保存…")
        static let snapshot = Words("支持快照", "Support snapshot", "サポート用スナップショット")
        static let snapshotNote = Words("诊断信息加上数据库版本，可以发给开发者。", "Diagnostics plus the database version, to send to a developer.", "診断情報とデータベースのバージョン。開発者に送れます。")
        static let backupCheck = Words("备份校验", "Backup check", "バックアップの確認")
        static let backupCheckNote = Words("在数据文件夹里选一个备份，检查它是否完整。", "Choose a backup in the data folder to check that it is intact.", "データフォルダのバックアップを選んで、壊れていないか確認します。")
        static let chooseBackup = Words("选择备份文件…", "Choose Backup…", "バックアップを選ぶ…")
        static let backupOK = Words("完整 · 数据库版本 {version} · {size}", "Intact · database version {version} · {size}", "問題なし・データベース {version}・{size}")
        static let cleanup = Words("清理旧数据", "Clean up old data", "古いデータの整理")
        static let previewCleanup = Words("看看能清理什么", "See What Can Go", "整理できるものを見る")
        static let cleanupNothing = Words("没有可以清理的旧数据。", "There is no old data to clean up.", "整理できる古いデータはありません。")
        static let cleanupFound = Words("可以清理 {count} 项：日志 {logs} · 抓取记录 {records} · 图片 {images} · 超过 24 小时的 X 帖子正文 {posts}", "{count} items can go: logs {logs} · fetch records {records} · images {images} · X post text older than 24 hours {posts}", "{count} 件を整理できます：ログ {logs}・取得記録 {records}・画像 {images}・24 時間を過ぎた X の投稿本文 {posts}")
        static let cleanupDeferred = Words("有图片正在使用，这次先不清理图片。", "Images are in use, so they are left for another time.", "画像が使用中のため、今回は画像を整理しません。")
        static let cleanButton = Words("清理…", "Clean Up…", "整理する…")
        static let cleanTitle = Words("清理旧数据？", "Clean up old data?", "古いデータを整理しますか？")
        static let cleanBody = Words("将删除上面列出的旧记录，不能撤销。", "The old records listed above are deleted. This cannot be undone.", "上に挙げた古い記録を削除します。元に戻せません。")
        static let cleanConfirm = Words("清理", "Clean Up", "整理する")
        static let cleaned = Words("已清理 {count} 项。", "Cleaned up {count} items.", "{count} 件を整理しました。")
        static let jobs = Words("任务与投递记录", "Jobs and deliveries", "処理と配信の記録")
        static let jobsLoad = Words("载入最近的记录", "Load Recent Records", "最近の記録を読み込む")
        static let jobsEmpty = Words("还没有任何任务。", "There are no jobs yet.", "まだ処理はありません。")
        static let jobHandedOff = Words("已交给投递", "Handed to delivery", "配信へ引き渡し済み")
        static let jobCancelled = Words("已取消", "Cancelled", "取り消し済み")
        static let sending = Words("正在发送", "Sending", "送信中")
        static let showDelivery = Words("投递明细", "Delivery details", "配信の詳細")
        static let noDelivery = Words("还没有投递记录。", "No delivery record yet.", "配信の記録はまだありません。")
        static let deliveryLine = Words("{bot} · {state} · 已发 {delivered} / 共 {parts} 段", "{bot} · {state} · {delivered} of {parts} parts sent", "{bot}・{state}・{parts} 件中 {delivered} 件送信")

        static let tomorrowAt = Words("明天 {time}", "tomorrow {time}", "明日 {time}")
        static let menuNext = Words("{status} · 下一期 {time} {digest}", "{status} · next {time} {digest}", "{status}・次回 {time} {digest}")
        static let menuPaused = Words("已暂停", "Paused", "一時停止中")

        static let noteApproval = Words("已登记，但需要你在「系统设置 › 通用 › 登录项」里允许 NewsPaw。", "Registered, but NewsPaw must be allowed in System Settings › General › Login Items.", "登録済みですが、「システム設定 › 一般 › ログイン項目」で NewsPaw を許可する必要があります。")
        static let noteUnavailable = Words("找不到 NewsPaw 的后台登记。把 NewsPaw 放进「应用程序」文件夹后重新打开。", "NewsPaw's background item was not found. Move NewsPaw to Applications and open it again.", "NewsPaw のバックグラウンド項目が見つかりません。NewsPaw を「アプリケーション」に移してから開き直してください。")
        static let noteNotPackaged = Words("开发版本没有登录项，自动启动和重启只在安装版里可用。", "A development build has no login item; starting at login and restarting work only in the installed app.", "開発版にはログイン項目がありません。ログイン時の起動と再起動はインストール版でのみ使えます。")
        static let noteLegacy = Words("旧版后台还在运行。先从原来的安装里停掉它再试。", "The previous backend is still running. Stop it from its original installation, then try again.", "以前のバックエンドがまだ動いています。元のインストールから止めてから再試行してください。")
        static let noteRefused = Words("macOS 没有完成这次登录项更改。到「系统设置 › 通用 › 登录项」里查看 NewsPaw 后再试。", "macOS did not make this login item change. Check NewsPaw in System Settings › General › Login Items, then try again.", "macOS がログイン項目を変更しませんでした。「システム設定 › 一般 › ログイン項目」で NewsPaw を確認してから再試行してください。")
        static let noteStartFailed = Words("没能启动后台。到「系统设置 › 通用 › 登录项」确认 NewsPaw 已允许后再试。", "The backend did not start. Make sure NewsPaw is allowed in System Settings › General › Login Items, then try again.", "バックエンドが起動しませんでした。「システム設定 › 一般 › ログイン項目」で NewsPaw が許可されているか確認してから再試行してください。")
        static let noteRestartNotStopped = Words("后台没有及时停下，所以这次没有重启。稍后再试。", "The backend did not stop in time, so it was not restarted. Try again shortly.", "バックエンドが時間内に止まらなかったため、再起動しませんでした。少し待って再試行してください。")
        static let noteStillRunning = Words("后台没有及时停下，自动启动没有关闭。稍后再试。", "The backend did not stop in time, so starting at login is still on. Try again shortly.", "バックエンドが時間内に止まらなかったため、ログイン時の起動はオンのままです。少し待って再試行してください。")

        static let all: [Words] = [
            intro, language, uiLanguage, uiLanguageNote, newsLanguage, newsLanguageNote, newsLanguageOffline,
            backend, status, running, notRunning, started, version, restart, restartHelp, stop, start, loginItem,
            loginItemNote, loginOffTitle, loginOffBody, loginOffButton, openLoginItems, pauseNote,
            data, storage, showInFinder, backup, backupNote, export, `import`, retention, retentionNote, days, saved,
            copied, imported, importTitle, importChanges, importNothing, importAgain, importStaysOff, importPairing,
            importKeys, importButton, changeUI, changeNews, changeTimezone, changeDigests, removeDigests, kindSources,
            kindBots, kindAccounts, kindModels, added, removed, changed, collectionLine, omittedLine,
            kindDigestTypes, typeLine, typeMoved, typeRenamed, otherChanges,
            advanced, advancedSummary, advancedNote, diagnostics, diagnosticsNote, copy, saveFile, snapshot, snapshotNote,
            backupCheck, backupCheckNote, chooseBackup, backupOK, cleanup, previewCleanup, cleanupNothing, cleanupFound,
            cleanupDeferred, cleanButton, cleanTitle, cleanBody, cleanConfirm, cleaned, jobs, jobsLoad, jobsEmpty,
            jobHandedOff, jobCancelled, sending, showDelivery, noDelivery, deliveryLine, tomorrowAt, menuNext, menuPaused,
            noteApproval, noteUnavailable, noteNotPackaged, noteLegacy, noteRefused, noteStartFailed, noteStillRunning,
            noteRestartNotStopped,
        ]
    }
}

/// "What happened. What to do." for a backend code (interaction-spec §2.4).
enum FailureCopy {
    struct Entry: Sendable {
        let message: Words
        let action: Words?
    }

    static let table: [String: Entry] = [
        "invalid_output": Entry(message: Words("模型回复了，但内容不符合要求。再测一次，或换一个模型。", "The model replied, but not in the expected form. Check again or choose another model.", "モデルは応答しましたが、想定した内容ではありませんでした。もう一度確認するか、別のモデルを選んでください。"), action: L10n.Shell.retry),
        "token_revoked": Entry(message: Words("Telegram 说这个 Token 已作废。到 @BotFather 重新生成后再粘贴。", "Telegram says this token was revoked. Make a new one with @BotFather and paste it.", "このトークンは無効になりました。@BotFather で再発行して貼り付けてください。"), action: L10n.Shell.retry),
        "forbidden": Entry(message: Words("Telegram 拒绝了这个机器人的请求。", "Telegram refused this Bot's request.", "Telegram がこのボットの要求を拒否しました。"), action: L10n.Shell.retry),
        "consumer_conflict": Entry(message: Words("另一个程序也在用这个 Token 读取消息。关掉它后再试。", "Another program is reading messages with this token. Stop it, then try again.", "別のプログラムがこのトークンでメッセージを読んでいます。止めてから再試行してください。"), action: L10n.Shell.retry),
        "missing_backup_credential": Entry(message: Words("备用模型还没有 Key（可选）。", "The backup model has no key (optional).", "予備モデルのキーがありません（任意）。"), action: nil),
        "authentication_failed": Entry(message: Words("模型服务说这个 Key 不对。复制完整 Key 再试。", "The model service says this key is wrong. Copy the full key and try again.", "モデルサービスによるとキーが正しくありません。完全なキーをコピーして再試行してください。"), action: L10n.Shell.retry),
        "model_unavailable": Entry(message: Words("找不到这个模型。检查模型 ID 或换一个模型。", "This model was not found. Check the model ID or choose another model.", "このモデルが見つかりません。モデル ID を確認するか、別のモデルを選んでください。"), action: L10n.Shell.retry),
        "permission_denied": Entry(message: Words("这个 Key 没有使用该模型的权限。", "This key is not allowed to use this model.", "このキーにはこのモデルを使う権限がありません。"), action: L10n.Shell.retry),
        "provider_failed": Entry(message: Words("模型服务出错了，稍后再试。", "The model service had an error; try again later.", "モデルサービスでエラーが発生しました。あとで再試行してください。"), action: L10n.Shell.retry),
        "protocol_error": Entry(message: Words("模型服务的回复格式不对。检查 API 地址是否兼容 OpenAI。", "The model service replied in an unexpected format. Check that the API address is OpenAI-compatible.", "モデルサービスの応答形式が想定と違います。API アドレスが OpenAI 互換か確認してください。"), action: L10n.Shell.retry),
        "invalid_probe_output": Entry(message: Words("模型回复了，但内容不符合测试要求。再测一次或换一个模型。", "The model replied, but not as the check requires. Check again or choose another model.", "モデルは応答しましたが、確認の条件を満たしませんでした。もう一度確認するか別のモデルを選んでください。"), action: L10n.Shell.retry),
        "bot_not_verified": Entry(message: Words("Telegram 没有确认这个机器人。检查 Token 后再验证。", "Telegram did not confirm this bot. Check the token and try again.", "Telegram がこのボットを確認できませんでした。トークンを確認して再試行してください。"), action: L10n.Shell.retry),
        "missing_token": Entry(message: Words("还没有填 Token。", "No token has been entered yet.", "トークンがまだ入力されていません。"), action: nil),
        "probe_pending": Entry(message: Words("Key 测试还没有结果。稍后点「再测一次」。", "The key check has no result yet. Use Check Again in a moment.", "キーの確認結果がまだありません。少ししてから「もう一度確認」を押してください。"), action: L10n.Shell.retry),
        "invalid_credential": Entry(message: Words("模型服务不接受这个 Key。复制完整 Key 再试。", "The model service did not accept this key. Copy the full key and try again.", "モデルサービスがこのキーを受け付けませんでした。完全なキーをコピーして再試行してください。"), action: L10n.Shell.retry),
        "connection_failed": Entry(message: Words("连不上模型服务。检查网络或 API 地址。", "Could not reach the model service. Check the network or the API address.", "モデルサービスに接続できませんでした。ネットワークか API アドレスを確認してください。"), action: L10n.Shell.retry),
        "credential_missing": Entry(message: Words("还没有保存 Key。", "No key is saved yet.", "キーがまだ保存されていません。"), action: nil),
        "credential_unavailable": Entry(message: Words("读不到保存的 Key（钥匙串可能被锁定）。", "The saved key could not be read (the keychain may be locked).", "保存したキーを読めません（キーチェーンがロックされている可能性があります）。"), action: L10n.Shell.retry),
        "invalid_endpoint": Entry(message: Words("这个 API 地址不能用。", "This API address cannot be used.", "この API アドレスは使えません。"), action: nil),
        "unsupported_provider": Entry(message: Words("不支持这个模型服务。", "This model service is not supported.", "このモデルサービスには対応していません。"), action: nil),
        "outcome_unknown": Entry(message: Words("测试消息已发出，但没收到确定结果。再测一次即可。", "The test message went out but no clear result came back. Check again.", "テストメッセージは送られましたが、結果がはっきりしません。もう一度確認してください。"), action: L10n.Shell.retry),
        "budget_blocked": Entry(message: Words("本月预算不够做这次测试。到「接入」调整上限。", "This month's budget does not cover the check. Adjust the limit in Connect.", "今月の予算では確認できません。「接続」で上限を調整してください。"), action: nil),
        "probe_unavailable": Entry(message: Words("这个模型服务暂时不能测试。", "This model service cannot be checked yet.", "このモデルサービスはまだ確認できません。"), action: nil),
        "adapter_not_implemented": Entry(message: Words("这个模型服务暂时不能测试。", "This model service cannot be checked yet.", "このモデルサービスはまだ確認できません。"), action: nil),
        "subscription_not_ready": Entry(message: Words("这份简报还不能开启，下面是还缺的。", "This digest cannot turn on yet; what is missing is listed below.", "このダイジェストはまだオンにできません。足りないものを下に示します。"), action: nil),
        "source_preview_required": Entry(message: Words("有来源还没试采集成功，先在来源里点「试采集」。", "A source has not been tried successfully yet; use Try Now on it first.", "まだ試しに取得できていないソースがあります。先に「試しに取得」してください。"), action: nil),
        "preview_required": Entry(message: Words("这个来源要先试采集成功才能启用。", "This source has to be tried successfully before it can be turned on.", "このソースは試しに取得できてから有効にできます。"), action: nil),
        "source_disabled": Entry(message: Words("这份简报用到的来源有的被关掉了。勾选它或从列表里去掉。", "A source this digest uses is turned off. Turn it on or remove it from the list.", "このダイジェストのソースにオフのものがあります。オンにするか一覧から外してください。"), action: nil),
        "no_ready_bot": Entry(message: Words("还没有可以发送的机器人。在「发送到」里选一个已配对的机器人。", "No Bot can receive it yet. Choose a paired Bot under Send to.", "送信できるボットがありません。「送信先」でペアリング済みのボットを選んでください。"), action: nil),
        "primary_unverified": Entry(message: Words("主模型的 Key 还没测试通过。去「接入」重新测试。", "The main model's key has not passed its check. Check it again in Connect.", "メインモデルのキーがまだ確認できていません。「接続」で再確認してください。"), action: nil),
        "backup_unverified": Entry(message: Words("备用模型的 Key 还没测试通过。去「接入」重新测试，或在高级里改回默认。", "The backup model's key has not passed its check. Check it in Connect, or switch back to Default under Advanced.", "予備モデルのキーがまだ確認できていません。「接続」で再確認するか、詳細でデフォルトに戻してください。"), action: nil),
        "schedule_missing": Entry(message: Words("还没有发送时间，至少加一个。", "There is no send time yet; add at least one.", "送信時刻がありません。1 つ以上追加してください。"), action: nil),
        "invalid_subscription_draft": Entry(message: Words("这次改动后台不接受，没有保存。", "The backend did not accept this change; nothing was saved.", "この変更はバックエンドに受け付けられず、保存されませんでした。"), action: nil),
        "missing_subscription": Entry(message: Words("这份简报已经不存在了（可能在别处删除了）。", "This digest no longer exists (it may have been removed elsewhere).", "このダイジェストはもうありません（別の場所で削除された可能性があります）。"), action: nil),
        "missing_source": Entry(message: Words("这个来源已经不存在了（可能在别处删除了）。", "This source no longer exists (it may have been removed elsewhere).", "このソースはもうありません（別の場所で削除された可能性があります）。"), action: nil),
        "duplicate_source": Entry(message: Words("这个来源已经添加过了。", "This source is already added.", "このソースは追加済みです。"), action: nil),
        "unclassified_source": Entry(message: Words("这个来源还没归入简报，先归入再试采集。", "This source is not in a digest yet; add it to one before trying it.", "このソースはまだダイジェストに入っていません。先に追加してください。"), action: nil),
        "adult_source_requires_adapter": Entry(message: Words("这是成人站点，只能加到成人简报里。", "This is an adult site; it can only be added to an adult digest.", "成人向けサイトのため、成人向けダイジェストにのみ追加できます。"), action: nil),
        "invalid_opml": Entry(message: Words("这个文件不是能读的 OPML。", "This file is not an OPML file NewsPaw can read.", "このファイルは読み込める OPML ではありません。"), action: nil),
        "discovery_failed": Entry(message: Words("没能从这个链接识别出新闻源。", "Could not find a news feed at this link.", "このリンクからニュースソースを見つけられませんでした。"), action: nil),
        "failed": Entry(message: Words("读取失败。", "Reading failed.", "読み込みに失敗しました。"), action: L10n.Shell.retry),
        "http_error": Entry(message: Words("网站返回了错误。", "The site returned an error.", "サイトがエラーを返しました。"), action: L10n.Shell.retry),
        "network_error": Entry(message: Words("连不上这个网站。", "Could not reach the site.", "サイトに接続できませんでした。"), action: L10n.Shell.retry),
        "interrupted": Entry(message: Words("读取被中断了，再试一次。", "Reading was interrupted; try again.", "読み込みが中断されました。もう一度お試しください。"), action: L10n.Shell.retry),
        "collection_held": Entry(message: Words("这个网站的读取暂时被暂停，稍后再试。", "Reading this site is on hold for now; try again later.", "このサイトの読み込みは一時的に止まっています。あとで再試行してください。"), action: L10n.Shell.retry),
        "cancelled": Entry(message: Words("读取被取消了。", "Reading was cancelled.", "読み込みがキャンセルされました。"), action: L10n.Shell.retry),
        "configuration_changed": Entry(message: Words("读取期间来源设置变了，再试一次。", "The source changed while it was being read; try again.", "読み込み中にソースの設定が変わりました。もう一度お試しください。"), action: L10n.Shell.retry),
        "identity_changed": Entry(message: Words("读取期间来源设置变了，再试一次。", "The source changed while it was being read; try again.", "読み込み中にソースの設定が変わりました。もう一度お試しください。"), action: L10n.Shell.retry),
        "redirect_rejected": Entry(message: Words("网站跳转到了不安全的地址，已停止。", "The site redirected somewhere unsafe, so reading stopped.", "サイトが安全でない場所へ転送したため停止しました。"), action: nil),
        "too_many_redirects": Entry(message: Words("网站跳转次数太多。", "The site redirected too many times.", "サイトの転送が多すぎます。"), action: nil),
        "private_address": Entry(message: Words("这个地址指向内网，不能读取。", "This address points to a private network and cannot be read.", "このアドレスは内部ネットワークを指しているため読み込めません。"), action: nil),
        "tls_hostname_mismatch": Entry(message: Words("网站的安全证书和地址不符。", "The site's security certificate does not match its address.", "サイトの証明書がアドレスと一致しません。"), action: nil),
        "response_too_large": Entry(message: Words("网站返回的内容太大。", "The site returned too much data.", "サイトのデータが大きすぎます。"), action: nil),
        "oversized_feed": Entry(message: Words("这个订阅源太大了。", "This feed is too large.", "このフィードは大きすぎます。"), action: nil),
        "parse_limit": Entry(message: Words("这个订阅源太复杂，读不完。", "This feed is too complex to read completely.", "このフィードは複雑すぎて読み切れません。"), action: nil),
        "invalid_html": Entry(message: Words("网页内容读不懂。", "The page could not be understood.", "ページの内容を解釈できませんでした。"), action: nil),
        "unsupported_encoding": Entry(message: Words("网站用的文字编码不支持。", "The site uses a text encoding NewsPaw does not support.", "サイトの文字コードに対応していません。"), action: nil),
        "invalid_publication_date": Entry(message: Words("条目的发布时间读不懂。", "The entries' publication dates could not be read.", "記事の公開日時を読み取れませんでした。"), action: nil),
        "preview_incomplete": Entry(message: Words("读到了网站，但还没有可用的条目，暂时不能启用。", "The site was read, but it has no usable entries yet, so it cannot be turned on.", "サイトは読めましたが、使える記事がまだないため有効にできません。"), action: L10n.Shell.retry),
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
        "invalid_amount": Entry(message: Words("请填整数美元，或留空表示不限。", "Enter a whole number of dollars, or leave it empty for no limit.", "ドルの整数を入力するか、空欄にして上限なしにしてください。"), action: nil),
        "invalid_count": Entry(message: Words("请填整数条数，或留空表示不限。", "Enter a whole number of reads, or leave it empty for no limit.", "件数を整数で入力するか、空欄にして上限なしにしてください。"), action: nil),
        "send_lane_busy": Entry(message: Words("这个机器人正在发别的消息，稍后再发测试消息。", "This bot is busy sending another message; send the test a little later.", "このボットは別のメッセージを送信中です。少ししてからテストを送ってください。"), action: L10n.Shell.retry),
        "binding_not_ready": Entry(message: Words("这个机器人还没配对好（或已暂停），配对后才能发送。", "This bot is not paired (or is paused); pair it before sending.", "このボットはまだペアリングされていない（または一時停止中）ため送信できません。"), action: nil),
        "request_id_conflict": Entry(message: Words("这条测试消息的记录对不上，请重新发一次。", "This test message's record does not match; send a new one.", "このテストメッセージの記録が一致しません。もう一度送ってください。"), action: L10n.Shell.retry),
        "invalid_test_request": Entry(message: Words("这条测试消息的请求无效，请重新发一次。", "This test request was not valid; send a new one.", "このテストの要求は無効です。もう一度送ってください。"), action: L10n.Shell.retry),
        "payload_rejected": Entry(message: Words("Telegram 不接受这条消息的内容。", "Telegram did not accept this message's content.", "Telegram がこのメッセージの内容を受け付けませんでした。"), action: nil),
        "rate_limit_invalid": Entry(message: Words("Telegram 要求放慢，但没说等多久。稍等一会儿再试。", "Telegram asked to slow down without saying for how long; try again shortly.", "Telegram から待機を求められましたが期間が不明です。少し待って再試行してください。"), action: L10n.Shell.retry),
        "invalid_bot_action": Entry(message: Words("这个机器人现在不能这样操作。", "This bot cannot do that right now.", "このボットは今その操作ができません。"), action: nil),
        "missing_bot": Entry(message: Words("这个机器人已经不存在了（可能在别处删除了）。", "This bot no longer exists (it may have been removed elsewhere).", "このボットはもうありません（別の場所で削除された可能性があります）。"), action: nil),
        "adult_permission_required": Entry(message: Words("这个机器人没有允许接收成人内容，先在「接入」里打开。", "This bot does not allow adult content; turn it on in Connect first.", "このボットは成人向けコンテンツを受け取れません。先に「接続」でオンにしてください。"), action: nil),
        "invalid_adult_permission": Entry(message: Words("没能改这个机器人的成人内容设置。", "The adult content setting of this bot could not be changed.", "このボットの成人向け設定を変更できませんでした。"), action: L10n.Shell.retry),
        "keychain_denied": Entry(message: Words("钥匙串拒绝了 NewsPaw 读取 Key。在钥匙串访问里允许后再试。", "The keychain refused to let NewsPaw read the key. Allow it in Keychain Access, then try again.", "キーチェーンが NewsPaw の読み取りを拒否しました。キーチェーンアクセスで許可してから再試行してください。"), action: L10n.Shell.retry),
        "keychain_unavailable": Entry(message: Words("现在用不了钥匙串。确认已登录这台 Mac 后再试。", "The keychain cannot be used right now. Make sure you are logged in to this Mac, then try again.", "今はキーチェーンを使えません。この Mac にログインしているか確認してから再試行してください。"), action: L10n.Shell.retry),
        "keychain_verification_failed": Entry(message: Words("Key 存进钥匙串后读回来不一致，没有保存。再试一次。", "The key read back from the keychain did not match, so nothing was saved. Try again.", "キーチェーンから読み戻したキーが一致せず、保存されませんでした。もう一度お試しください。"), action: L10n.Shell.retry),
        "configuration_commit_failed": Entry(message: Words("保存没有完成，原来的设置保留着。再试一次。", "Saving did not finish; the earlier settings are kept. Try again.", "保存が完了せず、元の設定のままです。もう一度お試しください。"), action: L10n.Shell.retry),
        "configuration_operation_failed": Entry(message: Words("保存没有完成，原来的设置保留着。再试一次。", "Saving did not finish; the earlier settings are kept. Try again.", "保存が完了せず、元の設定のままです。もう一度お試しください。"), action: L10n.Shell.retry),
        "missing_credential_entity": Entry(message: Words("要保存 Key 的模型或机器人已经不存在了。", "The model or bot this key belongs to no longer exists.", "このキーの保存先のモデルまたはボットはもうありません。"), action: nil),
        "invalid_credential_entity": Entry(message: Words("这个 Key 不能存到这里。", "This key cannot be stored here.", "このキーはここに保存できません。"), action: nil),
        "protected_configuration_field": Entry(message: Words("Key 和配对状态只能在「接入」里改。", "Keys and pairing can only be changed in Connect.", "キーとペアリングは「接続」でのみ変更できます。"), action: nil),
        "invalid_policy": Entry(message: Words("这个上限后台不接受，没有保存。", "The backend did not accept this limit; nothing was saved.", "この上限はバックエンドに受け付けられず、保存されませんでした。"), action: nil),
        "invalid_units": Entry(message: Words("金额或条数超出了范围，没有保存。", "The amount or count is out of range; nothing was saved.", "金額または件数が範囲外のため保存されませんでした。"), action: nil),
        "invalid_newspaper_settings": Entry(message: Words("这个模型不能用来生成报纸图，没有保存。", "This model cannot make newspaper images; nothing was saved.", "このモデルでは新聞画像を作れないため、保存されませんでした。"), action: nil),
        "invalid_media_settings": Entry(message: Words("这个模型不能用来转写语音，没有保存。", "This model cannot transcribe voice; nothing was saved.", "このモデルでは音声を文字起こしできないため、保存されませんでした。"), action: nil),
        "quota_exhausted": Entry(message: Words("模型服务的账户额度用完了。充值后再试。", "The model service account is out of credit. Add credit, then try again.", "モデルサービスの残高がありません。チャージしてから再試行してください。"), action: L10n.Shell.retry),
        "transport_rejected": Entry(message: Words("这个模型服务的地址不安全，没有连接。", "This model service address is not safe to connect to.", "このモデルサービスのアドレスは安全でないため接続しませんでした。"), action: nil),
        "missing_profile": Entry(message: Words("这个模型设置已经不存在了。", "This model setting no longer exists.", "このモデル設定はもうありません。"), action: nil),
        "image_capability_unavailable": Entry(message: Words("这个模型不能生成图片（只支持 OpenAI 官方地址）。", "This model cannot make images (only OpenAI's own address can).", "このモデルは画像を作れません（OpenAI 公式アドレスのみ対応）。"), action: nil),
        "stt_capability_unavailable": Entry(message: Words("这个模型不能转写语音（只支持 OpenAI 官方地址）。", "This model cannot transcribe voice (only OpenAI's own address can).", "このモデルは音声を文字起こしできません（OpenAI 公式アドレスのみ対応）。"), action: nil),
        "malformed_identity": Entry(message: Words("Telegram 返回的机器人信息不对，确认这是机器人的 Token。", "Telegram's reply about the bot was not valid; make sure this is a bot token.", "Telegram から返ったボット情報が正しくありません。ボットのトークンか確認してください。"), action: L10n.Shell.retry),
        "malformed_response": Entry(message: Words("Telegram 的回应看不懂，稍后再验证。", "Telegram's reply was not understood; check again later.", "Telegram の応答を解釈できません。あとで再確認してください。"), action: L10n.Shell.retry),
        "inbox_full": Entry(message: Words("这个机器人收到的消息太多还没处理完，稍后会继续。", "This bot has too many unprocessed messages; it continues shortly.", "このボットの未処理メッセージが多すぎます。少しすると続きを処理します。"), action: nil),
        "restore_requires_fresh_instance": Entry(message: Words("只能导入到还没开始使用的 NewsPaw。这里的设置已经改过，导入会覆盖它们，所以没有导入。", "Settings can only be imported into a NewsPaw that has not been used yet. These settings were already changed, so nothing was imported.", "読み込めるのはまだ使い始めていない NewsPaw だけです。ここの設定はすでに変更されているため、読み込みませんでした。"), action: nil),
        "invalid_portable_settings": Entry(message: Words("这个文件不是 NewsPaw 导出的设置，或者已经损坏。", "This file is not settings exported by NewsPaw, or it is damaged.", "このファイルは NewsPaw から書き出した設定ではないか、壊れています。"), action: nil),
        "settings_not_portable": Entry(message: Words("当前设置里有不能安全导出的内容（比如名称里像 Key 的文字）。改掉后再导出。", "Something in the settings cannot be exported safely (such as key-like text in a name). Change it, then export again.", "設定に安全に書き出せない内容（名前に含まれるキーのような文字など）があります。直してから書き出してください。"), action: nil),
        "invalid_backup": Entry(message: Words("这不是一个能用的 NewsPaw 备份。请在数据文件夹里选名字带「.backup-」的文件。", "This is not a usable NewsPaw backup. Choose a file named “….backup-…” in the data folder.", "使える NewsPaw のバックアップではありません。データフォルダにある「….backup-…」という名前のファイルを選んでください。"), action: nil),
        "invalid_cleanup": Entry(message: Words("清理的条件不对。换一个保留天数再试。", "The cleanup settings were not accepted. Choose another number of days and try again.", "整理の条件が受け付けられませんでした。保存期間を選び直して再試行してください。"), action: nil),
        "missing_delivery": Entry(message: Words("这一期还没有投递记录。", "This edition has no delivery record yet.", "この回の配信記録はまだありません。"), action: nil),
        "file_write_failed": Entry(message: Words("没能写入这个文件。换个位置再试。", "The file could not be written. Choose another place and try again.", "ファイルを書き込めませんでした。別の場所を選んで再試行してください。"), action: nil),
        "internal_error": Entry(message: Words("NewsPaw 内部出了问题，已记录在日志里。", "NewsPaw hit an internal problem and logged it.", "NewsPaw 内部で問題が起き、ログに記録しました。"), action: nil),
        // X accounts (R11). Codes shared with model or Telegram copy carry the "x." domain prefix.
        "x.authentication_failed": Entry(message: Words("X 拒绝了 X API Key（401）。到「接入」重新填入。", "X rejected the X API key (401). Enter it again in Connect.", "X が X API キーを拒否しました（401）。「接続」で入力し直してください。"), action: L10n.XAccounts.goConnect),
        "x.permission_denied": Entry(message: Words("这个 X Key 没有读取权限（403）。到 X 开发者后台检查后，在「接入」重新填入。", "This X key may not read (403). Check it in the X developer portal, then enter it again in Connect.", "この X キーには読み取り権限がありません（403）。X の開発者ポータルで確認し、「接続」で入力し直してください。"), action: L10n.XAccounts.goConnect),
        "x.credential_missing": Entry(message: Words("还没有填 X API Key。到「接入」填入后再试。", "No X API key yet. Enter one in Connect, then try again.", "X API キーがまだありません。「接続」で入力してから再試行してください。"), action: L10n.XAccounts.goConnect),
        "x.rate_limited": Entry(message: Words("X 说读取太频繁（429）。稍等几分钟再试。", "X says there are too many reads (429). Wait a few minutes and try again.", "X から読み取りが多すぎると言われました（429）。数分待って再試行してください。"), action: L10n.Shell.retry),
        "x.outcome_unknown": Entry(message: Words("X 没有及时回应，这次读取可能已经计入额度。确认后再试一次。", "X did not answer in time; this read may already count. Try once more.", "X が時間内に応答しませんでした。この読み取りは計上済みかもしれません。もう一度お試しください。"), action: L10n.Shell.retry),
        "x.unavailable": Entry(message: Words("X 上找不到它，可能不存在或已停用。", "X cannot find it; it may not exist or was suspended.", "X で見つかりません。存在しないか停止されている可能性があります。"), action: nil),
        "x.private": Entry(message: Words("这个 List 是私密的，读不到成员。", "This List is private, so its members cannot be read.", "このリストは非公開のため、メンバーを読み取れません。"), action: nil),
        "x.request_rejected": Entry(message: Words("X 拒绝了这次请求（400）。检查用户名或链接后再试。", "X refused this request (400). Check the username or link and try again.", "X がこのリクエストを拒否しました（400）。ユーザー名かリンクを確認して再試行してください。"), action: L10n.Shell.retry),
        "x.http_error": Entry(message: Words("X 出错了，稍后再试。", "X had an error; try again later.", "X でエラーが発生しました。あとで再試行してください。"), action: L10n.Shell.retry),
        "x.malformed_response": Entry(message: Words("X 的回应看不懂，稍后再试。", "X's reply was not understood; try again later.", "X の応答を解釈できません。あとで再試行してください。"), action: L10n.Shell.retry),
        "x.identity_mismatch": Entry(message: Words("这个用户名现在指向另一个账号（可能改过名）。重新验证一次。", "This username now belongs to another account (it may have been renamed). Check it again.", "このユーザー名は別のアカウントを指しています（名前が変わった可能性があります）。再確認してください。"), action: L10n.Shell.retry),
        "x.identity_conflict": Entry(message: Words("这个账号和列表里另一个账号对不上。先移除旧的再试。", "This account conflicts with another one in the list. Remove the old one and try again.", "このアカウントは一覧の別のアカウントと食い違っています。古い方を削除してから再試行してください。"), action: nil),
        "x.username_conflict": Entry(message: Words("这个用户名和列表里另一个账号冲突。先移除旧的再试。", "This username clashes with another account in the list. Remove the old one and try again.", "このユーザー名は一覧の別のアカウントと重なっています。古い方を削除してから再試行してください。"), action: nil),
        "x.interrupted": Entry(message: Words("读取被中断了，再试一次。", "The read was interrupted; try again.", "読み取りが中断されました。もう一度お試しください。"), action: L10n.Shell.retry),
        "x.cancelled": Entry(message: Words("读取被取消了，再试一次。", "The read was cancelled; try again.", "読み取りがキャンセルされました。もう一度お試しください。"), action: L10n.Shell.retry),
        "x.partial": Entry(message: Words("只读到了部分成员（最多 100 个），再读一次。", "Only some members were read (100 at most); read them again.", "メンバーの一部しか読み取れませんでした（最大 100 人）。もう一度読み取ってください。"), action: L10n.Shell.retry),
        "x.partial_response": Entry(message: Words("只读到了部分成员（最多 100 个），再读一次。", "Only some members were read (100 at most); read them again.", "メンバーの一部しか読み取れませんでした（最大 100 人）。もう一度読み取ってください。"), action: L10n.Shell.retry),
        "x.account_limit": Entry(message: Words("最多只能添加 200 个账号。先移除一些再添加。", "At most 200 accounts can be added. Remove some first.", "追加できるアカウントは最大 200 件です。先にいくつか削除してください。"), action: nil),
        "x_still_running": Entry(message: Words("X 还没回应。读完后结果会出现在列表里。", "X has not answered yet. The result appears in the list once it is read.", "X からまだ応答がありません。読み取りが終わると一覧に表示されます。"), action: nil),
        "x_limit": Entry(message: Words("今天的 X 读取已到上限。调高「每天最多读取」，或明天再试。", "Today's X reads are used up. Raise the reads per day, or try tomorrow.", "今日の X 読み取り上限に達しました。上限を上げるか、明日再試行してください。"), action: nil),
        "partition_limit": Entry(message: Words("这一类账号今天的 X 读取已到上限。在「高级」里调整。", "This kind of account has used up today's X reads. Adjust it under Advanced.", "この種類のアカウントは今日の X 読み取り上限に達しました。「詳細」で調整してください。"), action: nil),
        "account_limit": Entry(message: Words("这个账号今天的 X 读取已到上限。到「接入 › 费用」调整。", "This account has used up today's X reads. Adjust it in Connect › Spending.", "このアカウントは今日の X 読み取り上限に達しました。「接続 › 費用」で調整してください。"), action: L10n.XAccounts.goConnect),
        "task_limit": Entry(message: Words("这次读取超过了单次上限，没有进行。", "This read exceeded its own limit and did not run.", "この読み取りは 1 回あたりの上限を超えたため行いませんでした。"), action: nil),
        "operation_busy": Entry(message: Words("它正在读取中，稍等再试。", "It is being read right now; try again shortly.", "現在読み取り中です。少し待って再試行してください。"), action: L10n.Shell.retry),
        "missing_account": Entry(message: Words("这个账号已经不在列表里了（可能在别处移除了）。", "This account is no longer in the list (it may have been removed elsewhere).", "このアカウントはもう一覧にありません（別の場所で削除された可能性があります）。"), action: nil),
        "missing_list": Entry(message: Words("这个 List 已经不在了。", "This List is no longer here.", "このリストはもうありません。"), action: nil),
        "invalid_handle": Entry(message: Words("这不是有效的 X 用户名（1–15 个字母、数字或下划线）。", "This is not a valid X username (1–15 letters, digits or underscores).", "有効な X ユーザー名ではありません（英数字とアンダースコア 1〜15 文字）。"), action: nil),
        "invalid_list": Entry(message: Words("认不出这个 List 链接。复制 x.com/i/lists/… 形式的链接再试。", "This List link was not recognised. Copy an x.com/i/lists/… link and try again.", "このリストのリンクを認識できません。x.com/i/lists/… 形式のリンクをコピーしてください。"), action: nil),
        "list_conflict": Entry(message: Words("这个 List 已经加在另一类账号里了。", "This List is already added under the other kind of account.", "このリストはもう一方の種類にすでに追加されています。"), action: nil),
        "list_limit": Entry(message: Words("最多只能添加 30 个 List。", "At most 30 Lists can be added.", "追加できるリストは最大 30 件です。"), action: nil),
        "incompatible_subscription": Entry(message: Words("这个账号和那份汇总不是同一类（普通 / 成人），没有保存。", "This account and that digest are not the same kind (ordinary / adult); nothing was saved.", "このアカウントとまとめの種類（一般 / 成人向け）が違うため保存しませんでした。"), action: nil),
        "invalid_post_types": Entry(message: Words("至少要读一种帖子。", "Read at least one kind of post.", "少なくとも 1 種類の投稿を読み取ってください。"), action: nil),
        "invalid_account_overrides": Entry(message: Words("单独发的设置后台不接受，没有保存。", "The backend did not accept these send-alone settings; nothing was saved.", "単独配信の設定が受け付けられず、保存されませんでした。"), action: nil),
        "duplicate_target": Entry(message: Words("同一个机器人选了两次。", "The same Bot was chosen twice.", "同じボットが 2 回選ばれています。"), action: nil),
        "invalid_alert_rules": Entry(message: Words("提醒要先有至少一条规则才能开启。", "Alerts need at least one rule before they can be on.", "通知をオンにするにはルールが 1 つ以上必要です。"), action: nil),
        "duplicate_alert_rule": Entry(message: Words("这条规则已经有了。", "This rule already exists.", "このルールはすでにあります。"), action: nil),
        "invalid_alert_scope": Entry(message: Words("提醒只能用于汇总或单独发的账号。", "Alerts work only on the digest or on accounts sent alone.", "通知はまとめか単独で送るアカウントにのみ使えます。"), action: nil),
        "invalid_alert_settings": Entry(message: Words("提醒设置后台不接受，没有保存。", "The backend did not accept these alert settings; nothing was saved.", "通知の設定が受け付けられず、保存されませんでした。"), action: nil),
        "invalid_video_settings": Entry(message: Words("视频检查设置后台不接受，没有保存。", "The backend did not accept these video settings; nothing was saved.", "動画確認の設定が受け付けられず、保存されませんでした。"), action: nil),
        "invalid_video_budget": Entry(message: Words("视频检查的金额或次数超出范围，没有保存。", "The video amount or count is out of range; nothing was saved.", "動画確認の金額または回数が範囲外のため保存されませんでした。"), action: nil),
        "invalid_video_profiles": Entry(message: Words("视频检查需要能看图、能转写语音的普通模型（在「接入 › 附加能力」）。", "Video checks need ordinary models that see images and transcribe voice (Connect › Extras).", "動画の確認には画像認識と文字起こしができる一般モデルが必要です（「接続 › 追加機能」）。"), action: nil),
        "x.invalid_video_amount": Entry(message: Words("请填至少 1 的整数美元。", "Enter a whole number of dollars, at least 1.", "1 以上のドルの整数を入力してください。"), action: nil),
        "video_disabled": Entry(message: Words("视频内容检查还没开启。", "Video checks are not on.", "動画の確認はオンになっていません。"), action: nil),
        "video_daily_budget": Entry(message: Words("今天的视频检查已到上限（次数或金额）。明天再试，或调高每天最多花。", "Today's video checks are used up (count or amount). Try tomorrow, or raise the daily amount.", "今日の動画確認の上限（回数または金額）に達しました。明日再試行するか、1 日の上限を上げてください。"), action: nil),
        "video_request_in_progress": Entry(message: Words("另一个视频正在检查，等它完成再试。", "Another video is being checked; try when it is done.", "別の動画を確認中です。終わってから再試行してください。"), action: L10n.Shell.retry),
        "video_already_requested": Entry(message: Words("这个视频已经检查过了。", "This video was already checked.", "この動画はすでに確認しました。"), action: nil),
        "video_scope_changed": Entry(message: Words("检查设置或这期内容变了，之前的结果不再适用。", "The check settings or this edition changed, so the earlier result no longer applies.", "確認の設定かこの回の内容が変わったため、以前の結果は使えません。"), action: nil),
        "missing_video_request": Entry(message: Words("找不到这次检查的记录。", "No record of this check was found.", "この確認の記録が見つかりません。"), action: nil),
        "video_not_available": Entry(message: Words("这个帖子没有可以检查的视频。", "This post has no video to check.", "この投稿に確認できる動画はありません。"), action: nil),
        "video_metadata_unavailable": Entry(message: Words("读不到这个视频的信息。", "This video's details could not be read.", "この動画の情報を読み取れません。"), action: nil),
        "x.video_audio_unavailable": Entry(message: Words("没有声音可转写。", "There was no audio to transcribe.", "文字起こしできる音声がありませんでした。"), action: nil),
        "x.video_stt_unavailable": Entry(message: Words("声音没能转写。", "The audio could not be transcribed.", "音声を文字起こしできませんでした。"), action: nil),
        "x.video_vision_unavailable": Entry(message: Words("画面没能识别。", "The frames could not be analysed.", "映像を解析できませんでした。"), action: nil),
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
        // A code several services share (a 401, a 429) can have words for one service: "x.rate_limited".
        return table[error.domain + "." + error.code] ?? table[error.code]
            ?? Entry(message: fallback, action: error.retryable ? L10n.Shell.retry : nil)
    }

    static func message(for error: BackendError, _ language: AppLanguage) -> String {
        let entry = entry(for: error)
        return entry.message(language, ["code": error.code])
    }
}
