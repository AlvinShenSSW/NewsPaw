import Foundation
import Testing

@testable import NewsPaw

/// An in-memory backend for the X accounts page that follows the real operations' rules
/// (src/newspaw/x/accounts.py, telegram/targets.py, x/alerts.py, x/video.py): every account
/// change needs the current configuration revision; `x.accounts.add` only creates a draft (or
/// returns the account with that username); `x.accounts.verify` reads X once under a request id
/// and records the outcome; `x.accounts.route` resets an account's own time, Bots and style when
/// its priority changes; `x.accounts.classify` clears its digest; alerts and video policies
/// check their whole settings document.
@MainActor
private final class XBackend {
    struct User { let remote: String; var protected = false }

    var revision = 1
    var document: [String: Any]
    /// x_identities: state and when it was observed, per account.
    var identities: [String: (state: String, observed: String?)] = [:]
    var remoteOwners: [String: String] = [:]
    /// Accounts on "X", by lowercased username.
    var users: [String: User] = [:]
    /// A read failure X gives for every read (`rate_limited`, `outcome_unknown`, …).
    var readFailure: String?
    /// The budget refuses reads with this reason (`x_limit`, `partition_limit`, …).
    var budgetBlock: String?
    /// The next verify reply is lost (socket deadline) after the backend recorded it.
    var dropNextVerify = false
    private var operations: [String: [String: Any]] = [:]
    var lists: [String: [String: Any]] = [:]
    var listMembers: [String: [(handle: String, remote: String)]] = [:]
    var privateLists: Set<String> = []
    var budgetRevision = 1
    var budget: [String: Any] = [
        "model": ["monthly_limit": 20_000_000, "image_limit": NSNull(), "provider_limits": [String: Any](), "timezone": "Asia/Tokyo", "cycle_day": 1],
        "x": ["daily_limit": 200, "partition_limits": ["normal": NSNull(), "adult": NSNull()], "account_limits": [String: Any](), "timezone": "Asia/Tokyo"],
    ]
    var periods: [[String: Any]] = []
    var alertsRevision = 1
    var alerts: [String: Any] = [
        "enabled": false, "timezone": "Asia/Tokyo", "daily_limit": 0, "cooldown_minutes": 120,
        "quiet_start": NSNull(), "quiet_end": NSNull(), "max_age_minutes": 180, "rules": [[String: Any]](),
    ]
    var videoRevision = 1
    var video: [String: Any] = [
        "enabled": false, "timezone": "Asia/Tokyo", "daily_limit": 0, "daily_model_limit": 0,
        "vision_profiles": [String](), "stt_profiles": [String](), "vision_hold": 0, "stt_hold": 0,
    ]
    var candidates: [[String: Any]] = []
    var coverage: [String: String] = [:]
    var posts: [String: [String]] = [:]
    private(set) var requests: [[String: Any]] = []
    private var serial = 0
    /// Runs once just before the next `x.alerts.save` is checked.
    var beforeAlertsSave: ((XBackend) -> Void)?
    /// Refuses any request this returns a code for (e.g. only route requests carrying post types).
    var refuseWhen: (([String: Any]) -> String?)?
    /// Refuses the next request of an operation with this code, once.
    var failNext: [String: String] = [:]
    /// Per-operation delays before the reply is computed (to overlap requests).
    var delays: [String: [Duration]] = [:]

    func nextDelay(_ op: String) -> Duration? {
        guard var queue = delays[op], !queue.isEmpty else { return nil }
        let delay = queue.removeFirst()
        delays[op] = queue
        return delay
    }

    init(xKey: Bool = true, accounts: [[String: Any]] = [], adultModel: Bool = true) {
        document = [
            "ui_locale": "en", "news_output_locale": "en", "owner_id": 7, "timezone": "Asia/Tokyo",
            "x_api": ["credential_ref": xKey ? "keychain:x" as Any : NSNull()],
            "categories": [
                ["id": "x", "name": "X", "partition": "normal"], ["id": "x_adult", "name": "X adult", "partition": "adult"],
            ],
            "subscriptions": [
                ["id": "sub_x", "category_id": "x", "timezone": "Asia/Tokyo", "enabled": true, "times": ["20:30"], "bot_ids": ["bot1"], "style": "text", "source_ids": []],
                ["id": "sub_xa", "category_id": "x_adult", "timezone": "Asia/Tokyo", "enabled": true, "times": ["22:00"], "bot_ids": ["bot_adult"], "style": "text", "source_ids": []],
            ],
            "sources": [], "accounts": accounts,
            "bots": [
                ["id": "bot1", "name": "Main", "adult_allowed": false, "credential_ref": "keychain:b1"],
                ["id": "bot2", "name": "Second", "adult_allowed": false, "credential_ref": "keychain:b2"],
                ["id": "bot_adult", "name": "Night", "adult_allowed": true, "credential_ref": "keychain:b3"],
            ],
            "model_profiles": [
                ["id": "normal_primary", "partition": "normal", "role": "primary", "provider": "openai", "base_url": "https://api.openai.com/v1",
                 "model": "gpt", "credential_ref": "keychain:m1", "capabilities": ["text", "vision", "stt"]],
                ["id": "adult_primary", "partition": "adult", "role": "primary", "provider": "deepseek", "base_url": "https://api.deepseek.com",
                 "model": "ds", "credential_ref": adultModel ? "keychain:m2" as Any : NSNull(), "capabilities": ["text"]],
            ],
        ]
        for account in accounts {
            let id = account["id"] as! String
            if let remote = account["remote_id"] as? String {
                remoteOwners[remote] = id
                identities[id] = ("ready", "2026-11-09T14:10:00+00:00")
            }
        }
    }

    static func account(_ id: String, _ handle: String, partition: String? = "normal", subscription: String? = "sub_x",
                        priority: String = "normal", remote: String? = nil, times: Any = NSNull(), bots: Any? = nil) -> [String: Any] {
        ["id": id, "remote_id": remote ?? NSNull(), "handle": handle, "partition": partition ?? NSNull(), "priority": priority,
         "subscription_id": subscription ?? NSNull(), "bot_ids": bots ?? (priority == "special" ? NSNull() : [String]()),
         "times": times, "style": NSNull()]
    }

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    var accounts: [[String: Any]] { document["accounts"] as! [[String: Any]] }
    func stored(_ id: String) -> [String: Any]? { accounts.first { $0["id"] as? String == id } }
    func stored(handle: String) -> [String: Any]? { accounts.first { ($0["handle"] as! String).lowercased() == handle.lowercased() } }
    private var subscriptions: [[String: Any]] { document["subscriptions"] as! [[String: Any]] }

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let op = request["op"] as! String
            if let delay = await MainActor.run(body: { self.nextDelay(op) }) { try await Task.sleep(for: delay) }
            let reply = await MainActor.run { () -> Data? in self.answer(request) }
            guard let reply else { throw SocketFailure.timeout }
            return reply
        }
    }

    private func ok(_ result: Any) -> Data { try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }
    private func refuse(_ code: String, _ domain: String = "x") -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": domain, "retryable": false]])
    }

    private func edit(_ id: String, _ change: (inout [String: Any]) -> Void) {
        document["accounts"] = accounts.map { entry in
            guard entry["id"] as? String == id else { return entry }
            var entry = entry
            change(&entry)
            return entry
        }
    }

    private func status(_ account: [String: Any]) -> [String: Any] {
        let id = account["id"] as! String
        let observed = identities[id]
        var state = observed?.state ?? "unverified"
        if ["ready", "protected"].contains(state), account["remote_id"] is NSNull { state = "unverified" }
        let partition = account["partition"] as? String
        let sub = subscriptions.first { $0["id"] as? String == account["subscription_id"] as? String }
        let expected = partition == "adult" ? "x_adult" : "x"
        let collect = state == "ready" && partition != nil && sub?["category_id"] as? String == expected && sub?["enabled"] as? Bool == true
        return account.merging([
            "state": state, "observed_at": observed?.observed ?? NSNull(), "direct": true, "member_active": false, "can_collect": collect,
        ]) { _, new in new }
    }

    private func listStatus(_ id: String) -> [String: Any] {
        var entry = lists[id]!
        entry["current"] = entry["state"] as? String == "ready"
        return entry
    }

    private func category(_ subscription: String?) -> String? {
        subscriptions.first { $0["id"] as? String == subscription }?["category_id"] as? String
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func answer(_ request: [String: Any]) -> Data? {
        requests.append(request)
        let op = request["op"] as! String
        // A one-off refusal of the next request of this operation (e.g. a storage failure).
        if let code = failNext.removeValue(forKey: op) { return refuse(code) }
        if let code = refuseWhen?(request) { return refuse(code) }
        let stale = (request["revision"] as? Int).map { $0 != revision } ?? false
        let id = request["account_id"] as? String ?? ""
        switch op {
        case "service.status": return ok(["protocol_version": 1, "state": "running", "operations": ["setup.readiness"]])
        case "setup.readiness": return ok(["complete": true, "next": NSNull(), "scheduling_enabled": true, "steps": []])
        case "config.get": return ok(["revision": revision, "document": document])
        case "config.save":
            if stale { return refuse("config_conflict", "config") }
            let next = request["document"] as! [String: Any]
            // validate_config: an account's digest must be of its own kind.
            for account in next["accounts"] as! [[String: Any]] {
                guard let sub = account["subscription_id"] as? String else { continue }
                let partition = account["partition"] as? String
                if category(sub) != (partition == "adult" ? "x_adult" : partition == "normal" ? "x" : "none") {
                    return refuse("invalid_request", "config")
                }
            }
            document = next
            revision += 1
            return ok(["revision": revision])
        case "bots.list":
            return ok(["bot1", "bot2", "bot_adult"].map { bot in
                ["id": bot, "name": bot, "verified": true, "paired": true, "paused": false, "generation": 1, "status": "paired", "username": bot] as [String: Any]
            })
        case "newspaper.policy": return ok(["revision": 1, "settings": ["enabled": false, "generation_profile": NSNull()]])
        case "x.accounts.list":
            return ok(["revision": revision, "credential_configured": (document["x_api"] as! [String: Any])["credential_ref"] is String,
                       "accounts": accounts.map(status)])
        case "x.accounts.add":
            let raw = (request["handle"] as! String).trimmingCharacters(in: .whitespaces)
            let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
            guard name.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil else { return refuse("invalid_handle") }
            let partition = request["partition"] as? String
            if let partition, !["normal", "adult"].contains(partition) { return refuse("invalid_partition") }
            if stale { return refuse("config_conflict", "x") }
            if let existing = stored(handle: name) { return ok(["revision": revision, "account": status(existing)]) }
            if accounts.count >= 200 { return refuse("account_limit") }
            serial += 1
            let draft = Self.account("accounts_\(serial)", name.lowercased(), partition: partition, subscription: nil)
            document["accounts"] = accounts + [draft]
            revision += 1
            return ok(["revision": revision, "account": status(draft)])
        case "x.accounts.route":
            if stale { return refuse("config_conflict", "x") }
            guard var account = stored(id) else { return refuse("missing_account") }
            let priority = request["priority"] as! String
            let sub = request["subscription_id"] as? String
            guard ["normal", "special"].contains(priority) else { return refuse("invalid_priority") }
            if let overrides = request["overrides"] {
                guard let fields = overrides as? [String: Any], Set(fields.keys) == ["times", "bot_ids", "style"], priority == "special", sub != nil else {
                    return refuse("invalid_account_overrides")
                }
            }
            if let types = request["post_types"] as? [String], types.isEmpty || !Set(types).isSubset(of: Set(XPostType.all)) {
                return refuse("invalid_post_types")
            }
            let partition = account["partition"] as? String
            if let sub, partition == nil || category(sub) != (partition == "adult" ? "x_adult" : "x") { return refuse("incompatible_subscription") }
            if account["priority"] as? String != priority {
                account["bot_ids"] = priority == "special" ? NSNull() : [String]()
                account["times"] = NSNull()
                account["style"] = NSNull()
            }
            if priority != "special" || account["subscription_id"] as? String != sub { account.removeValue(forKey: "include_in_aggregate") }
            if let types = request["post_types"] as? [String] {
                if Set(types) == Set(XPostType.defaults) { account.removeValue(forKey: "post_types") } else { account["post_types"] = types }
            }
            if let overrides = request["overrides"] as? [String: Any] {
                if let bots = overrides["bot_ids"] as? [String], partition == "adult",
                   bots.contains(where: { bot in !((document["bots"] as! [[String: Any]]).first { $0["id"] as? String == bot }?["adult_allowed"] as? Bool ?? false) }) {
                    return refuse("adult_permission_required", "targets")
                }
                account["times"] = overrides["times"]
                account["style"] = overrides["style"]
                account["bot_ids"] = overrides["bot_ids"]
            }
            account["subscription_id"] = sub ?? NSNull()
            account["priority"] = priority
            edit(id) { $0 = account }
            revision += 1
            return ok(["revision": revision, "affected_accounts": [id]])
        case "x.accounts.verify":
            let requestId = request["request_id"] as! String
            if let prior = operations[requestId] { return ok(prior) }
            if stale { return refuse("config_conflict", "x") }
            guard let account = stored(id) else { return refuse("missing_account") }
            var record: [String: Any] = ["request_id": requestId, "kind": "account", "scope_id": id, "attempts": [], "updated_at": "now"]
            let handle = (account["handle"] as! String).lowercased()
            if let budgetBlock {
                record.merge(["state": "budget_blocked", "reason": budgetBlock, "retry_after": NSNull()]) { _, new in new }
            } else if let readFailure {
                record.merge(["state": readFailure, "reason": readFailure, "retry_after": NSNull()]) { _, new in new }
                if ["permission_denied", "authentication_failed", "unavailable"].contains(readFailure) { identities[id] = (readFailure, "2026-11-10T00:00:00+00:00") }
            } else if let user = users[handle] {
                if let owner = remoteOwners[user.remote], owner != id, stored(owner) != nil {
                    record.merge(["state": "duplicate", "revision": revision, "account": status(stored(owner)!), "canonical_account_id": owner]) { _, new in new }
                } else {
                    edit(id) { $0["remote_id"] = user.remote }
                    remoteOwners[user.remote] = id
                    identities[id] = (user.protected ? "protected" : "ready", "2026-11-10T00:00:00+00:00")
                    revision += 1
                    record.merge(["state": user.protected ? "protected" : "ready", "revision": revision, "account": status(stored(id)!),
                                  "canonical_account_id": id]) { _, new in new }
                }
            } else {
                identities[id] = ("unavailable", "2026-11-10T00:00:00+00:00")
                record.merge(["state": "unavailable", "reason": "unavailable", "retry_after": NSNull()]) { _, new in new }
            }
            operations[requestId] = record
            if dropNextVerify {
                dropNextVerify = false
                return nil
            }
            return ok(record)
        case "x.operation":
            guard let record = operations[request["request_id"] as! String] else { return refuse("missing_operation") }
            return ok(record)
        case "x.accounts.classify":
            if stale { return refuse("config_conflict", "targets") }
            let partition = request["partition"] as? String
            edit(id) { entry in
                guard entry["partition"] as? String != partition else { return }
                entry.removeValue(forKey: "include_in_aggregate")
                entry.removeValue(forKey: "post_types")
                entry["partition"] = partition ?? NSNull()
                entry["subscription_id"] = NSNull()
                entry["bot_ids"] = [String]()
                entry["times"] = NSNull()
                entry["style"] = NSNull()
            }
            revision += 1
            return ok(["revision": revision])
        case "x.accounts.partition_impact":
            guard let account = stored(id) else { return refuse("missing_account") }
            let sub = subscriptions.first { $0["id"] as? String == account["subscription_id"] as? String }
            let special = sub != nil && account["priority"] as? String == "special"
            let aggregate = sub != nil && account["priority"] as? String == "normal"
            return ok([
                "revision": revision, "account_id": id, "partition": account["partition"]!, "subscription_id": account["subscription_id"]!,
                "aggregate": aggregate, "special": special,
                "aggregate_bot_ids": aggregate ? sub!["bot_ids"]! : [String](),
                "special_bot_ids": special ? ((account["bot_ids"] as? [String]) ?? (sub!["bot_ids"] as! [String])) : [String](),
                "clears_special_overrides": special, "clears_post_types": account["post_types"] != nil,
                "cached_posts": 4, "pending_jobs": 1,
            ])
        case "x.accounts.remove":
            if stale { return refuse("config_conflict", "targets") }
            guard stored(id) != nil else { return refuse("missing_account", "targets") }
            document["accounts"] = accounts.filter { $0["id"] as? String != id }
            revision += 1
            return ok(["revision": revision])
        case "x.lists.list": return ok(lists.keys.sorted().map(listStatus))
        case "x.lists.add":
            if stale { return refuse("config_conflict", "x") }
            let value = request["value"] as! String
            guard let match = value.range(of: "[0-9]+$", options: .regularExpression), value.contains("/i/lists/") else { return refuse("invalid_list") }
            let listId = String(value[match])
            let partition = request["partition"] as! String
            let adult = request["default_adult"] as? Bool ?? false
            if let existing = lists[listId] {
                if existing["partition"] as? String != partition { return refuse("list_conflict") }
            } else {
                lists[listId] = ["id": listId, "partition": partition, "default_adult": adult, "name": NSNull(), "state": "unverified",
                                 "members": [[String: Any]](), "checked_at": NSNull()]
            }
            return ok(listStatus(listId))
        case "x.lists.refresh":
            if stale { return refuse("config_conflict", "x") }
            let listId = request["list_id"] as! String
            guard var list = lists[listId] else { return refuse("missing_list") }
            if let readFailure {
                // _failure(): a failed read of a List records its state; members stay as they were.
                list["state"] = readFailure
                lists[listId] = list
                return ok(["request_id": request["request_id"]!, "state": readFailure, "reason": readFailure, "retry_after": NSNull()])
            }
            if privateLists.contains(listId) {
                list["state"] = "private"
                lists[listId] = list
                return ok(["request_id": request["request_id"]!, "state": "private", "list": listStatus(listId)])
            }
            var members: [[String: Any]] = []
            var changed = false
            for member in listMembers[listId] ?? [] {
                var owner = remoteOwners[member.remote] ?? stored(handle: member.handle)?["id"] as? String
                if owner == nil {
                    serial += 1
                    let draft = Self.account("accounts_\(serial)", member.handle, partition: list["default_adult"] as! Bool ? "adult" : nil,
                                             subscription: nil, remote: member.remote)
                    document["accounts"] = accounts + [draft]
                    owner = draft["id"] as? String
                    changed = true
                }
                remoteOwners[member.remote] = owner
                identities[owner!] = ("ready", "2026-11-10T00:00:00+00:00")
                members.append(["account_id": owner!, "remote_id": member.remote])
            }
            if changed { revision += 1 }
            list.merge(["name": "AI people", "state": "ready", "members": members, "checked_at": "2026-11-10T00:00:00+00:00"]) { _, new in new }
            lists[listId] = list
            return ok(["request_id": request["request_id"]!, "state": "ready", "revision": revision, "list": listStatus(listId)])
        case "x.posts.coverage":
            let scope = request["scope"] as! String
            return ok(["state": "complete", "latest": coverage[scope].map { ["observed_at": $0, "completed_pages": 1] as Any } ?? NSNull(), "last_complete": NSNull()])
        case "x.posts.list":
            return ok((posts[request["scope"] as! String] ?? []).map { ["id": "1", "published_at": $0] })
        case "budget.get":
            return ok(["revision": budgetRevision, "document": budget, "report": ["policy_revision": budgetRevision, "periods": periods]])
        case "budget.save":
            if request["revision"] as? Int != budgetRevision { return refuse("budget_policy_conflict", "budget") }
            budget = request["document"] as! [String: Any]
            budgetRevision += 1
            return ok(["revision": budgetRevision])
        case "x.alerts.status": return ok(["revision": alertsRevision, "settings": alerts, "occurrences": []])
        case "x.alerts.save":
            if let change = beforeAlertsSave {
                // Another writer saves first (a Telegram command, another window).
                beforeAlertsSave = nil
                change(self)
            }
            if request["revision"] as? Int != alertsRevision { return refuse("alert_policy_changed") }
            let settings = request["settings"] as! [String: Any]
            let rules = settings["rules"] as! [[String: Any]]
            if settings["enabled"] as! Bool, rules.isEmpty || settings["daily_limit"] as! Int == 0 { return refuse("invalid_alert_rules") }
            var seen = Set<String>()
            for rule in rules {
                let key = "\(rule["subscription_id"]!)|\(rule["account_id"]!)|\((rule["phrase"] as! String).lowercased())"
                if !seen.insert(key).inserted { return refuse("duplicate_alert_rule") }
                // configure(): a rule on an account needs that account sent alone.
                if let account = rule["account_id"] as? String, stored(account)?["priority"] as? String != "special" {
                    return refuse("invalid_alert_scope")
                }
            }
            alerts = settings
            alertsRevision += 1
            return ok(["revision": alertsRevision, "settings": alerts, "occurrences": []])
        case "x.video.policy": return ok(["revision": videoRevision, "settings": video])
        case "x.video.save":
            if request["revision"] as? Int != videoRevision { return refuse("video_policy_changed", "media") }
            let settings = request["settings"] as! [String: Any]
            let on = settings["enabled"] as! Bool ? 1 : 0
            for key in ["daily_limit", "daily_model_limit", "vision_hold", "stt_hold"] where (settings[key] as! Int) < on {
                return refuse("invalid_video_budget", "media")
            }
            for key in ["vision_profiles", "stt_profiles"] where (settings[key] as! [String]).count < on {
                return refuse("invalid_video_profiles", "media")
            }
            // configure(): every stored id must still be an ordinary model with that capability,
            // whether video checks are being turned on or off.
            let profiles = document["model_profiles"] as! [[String: Any]]
            for (key, capability) in [("vision_profiles", "vision"), ("stt_profiles", "stt")] {
                for identity in settings[key] as! [String] {
                    guard let profile = profiles.first(where: { $0["id"] as? String == identity }), profile["partition"] as? String == "normal",
                          (profile["capabilities"] as! [String]).contains(capability) else { return refuse("invalid_video_profiles", "media") }
                }
            }
            video = settings
            videoRevision += 1
            return ok(["revision": videoRevision, "settings": video])
        case "x.video.candidates": return ok(candidates)
        case "x.video.inspect":
            guard video["enabled"] as! Bool else { return refuse("video_disabled", "media") }
            let result: [String: Any] = ["request_id": request["request_id"]!, "job_id": request["job_id"]!, "post_id": request["post_id"]!,
                                         "state": "complete", "frames": [["second": 1.0, "observation": "A stage"]], "transcript": "hello", "gaps": []]
            candidates = candidates.map { var entry = $0; if entry["post_id"] as? String == request["post_id"] as? String { entry["request_id"] = request["request_id"] }; return entry }
            return ok(result)
        default: return refuse("unknown_operation", "protocol")
        }
    }
}

@MainActor
private func connected(_ server: XBackend) async throws -> (AppModel, XAccountsData, () -> Void) {
    let name = "NewsPawXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let model = AppModel(client: server.client, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    let data = XAccountsData(defaults: defaults)
    data.pollInterval = .milliseconds(5)
    data.followLimit = .seconds(2)
    await data.load(model: model)
    return (model, data, { defaults.removePersistentDomain(forName: name) })
}

// MARK: - Adding (§7.2)

@Test @MainActor func aReadableAccountIsAddedInlineIntoItsKindsDigest() async throws {
    let server = XBackend()
    server.users["openai"] = .init(remote: "4398626122")
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("@OpenAI", partition: "normal", model: model)

    let account = try #require(server.stored(handle: "openai"))
    let id = account["id"] as! String
    #expect(data.outcome == .added(id) && data.highlighted == id)
    #expect(account["partition"] as? String == "normal" && account["subscription_id"] as? String == "sub_x" && account["priority"] as? String == "normal")
    #expect(server.calls("x.accounts.add").first?["partition"] as? String == "normal")
    // One read of X under a request id, against the current revision.
    let verify = try #require(server.calls("x.accounts.verify").first)
    #expect(verify["request_id"] is String && verify["revision"] as? Int == server.revision - 1)
    #expect(data.accounts(in: "normal").map(\.id) == [id] && data.accounts(in: "adult").isEmpty)
    #expect(XAccountState(try #require(data.account(id)).state) == .readable)
}

@Test @MainActor func aProtectedAccountAsksToKeepOrDiscard() async throws {
    let server = XBackend()
    server.users["private_friend"] = .init(remote: "11", protected: true)
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("private_friend", partition: "normal", model: model)
    let id = try #require(server.stored(handle: "private_friend")?["id"] as? String)
    #expect(data.outcome == .protected(id))
    #expect(XAccountState(try #require(data.account(id)).state) == .protected)
    #expect(XAccountState("protected").removable)

    data.keep(id)
    #expect(data.outcome == nil && server.stored(id) != nil)

    server.users["second"] = .init(remote: "12", protected: true)
    await data.add("second", partition: "normal", model: model)
    let second = try #require(server.stored(handle: "second")?["id"] as? String)
    await data.discard(second, model: model)
    #expect(server.stored(second) == nil && data.outcome == nil)
}

@Test @MainActor func anAccountXDoesNotKnowIsNamedAndLeavesNothingBehind() async throws {
    let server = XBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("nobody_here", partition: "normal", model: model)

    #expect(data.outcome == .missing("nobody_here"))
    #expect(server.accounts.isEmpty && data.accounts.isEmpty)
    for language in AppLanguage.allCases {
        #expect(L10n.XAccounts.missingResult(language, ["handle": "@nobody_here"]).contains("@nobody_here"))
    }
}

@Test @MainActor func aKnownUsernameIsShownNotReadAgainAndNeverMovedAcrossKinds() async throws {
    let server = XBackend(accounts: [
        XBackend.account("a1", "sama", remote: "1"),
        XBackend.account("a2", "night", partition: "adult", subscription: "sub_xa", remote: "2"),
    ])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("@Sama", partition: "normal", model: model)
    #expect(data.outcome == .exists("a1") && data.highlighted == "a1")

    await data.add("night", partition: "normal", model: model)
    #expect(data.outcome == .otherPartition("night", "adult"))
    #expect(server.calls("x.accounts.add").isEmpty && server.calls("x.accounts.verify").isEmpty)
    #expect(server.stored("a2")?["partition"] as? String == "adult")
}

@Test @MainActor func theSameXAccountUnderANewUsernameIsNotAddedTwice() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "oldname", remote: "77")])
    server.users["newname"] = .init(remote: "77")
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("newname", partition: "normal", model: model)

    #expect(data.outcome == .exists("a1"))
    #expect(server.accounts.map { $0["id"] as! String } == ["a1"])
}

@Test @MainActor func aFailedReadKeepsTheDraftWithXSpecificWordsAndCanBeRetried() async throws {
    let server = XBackend()
    server.users["karpathy"] = .init(remote: "33")
    server.readFailure = "rate_limited"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("karpathy", partition: "normal", model: model)
    let id = try #require(server.stored(handle: "karpathy")?["id"] as? String)
    guard case let .failed(failure, draft) = data.outcome else { Issue.record("no failure: \(String(describing: data.outcome))"); return }
    #expect(failure == BackendError(code: "rate_limited", domain: "x") && draft == id)
    // X's 429, not the model service's.
    for language in AppLanguage.allCases {
        #expect(FailureCopy.message(for: failure, language) != FailureCopy.message(for: BackendError(code: "rate_limited", domain: "models"), language))
        #expect(FailureCopy.message(for: failure, language).contains("429"))
    }
    #expect(FailureCopy.entry(for: failure).action != nil)

    server.readFailure = nil
    await data.retryAdd(id, partition: "normal", model: model)
    #expect(data.outcome == .added(id) && server.calls("x.accounts.verify").count == 2)
    // A retry is a new read with a new request id.
    let ids = server.calls("x.accounts.verify").map { $0["request_id"] as! String }
    #expect(Set(ids).count == 2)
}

@Test @MainActor func aReadStoppedByAReadLimitNamesThatLimit() async throws {
    let server = XBackend()
    server.users["sama"] = .init(remote: "5")
    server.budgetBlock = "x_limit"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("sama", partition: "normal", model: model)
    guard case let .failed(failure, _) = data.outcome else { Issue.record("no failure"); return }
    #expect(failure.code == "x_limit")
    #expect(FailureCopy.table["x_limit"] != nil && FailureCopy.table["partition_limit"] != nil && FailureCopy.table["account_limit"] != nil)
    // The 200-account cap of x.accounts.add is a different sentence from a read limit.
    #expect(FailureCopy.message(for: BackendError(code: "account_limit", domain: "x"), .en)
        != FailureCopy.message(for: BackendError(code: "account_limit", domain: "budget"), .en))
}

@Test @MainActor func aReadThatOutlivesTheSocketIsFollowedNotReportedAsLost() async throws {
    let server = XBackend()
    server.users["openai"] = .init(remote: "9")
    server.dropNextVerify = true
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("openai", partition: "normal", model: model)

    let id = try #require(server.stored(handle: "openai")?["id"] as? String)
    #expect(data.outcome == .added(id))
    #expect(server.calls("x.accounts.verify").count == 1)
    #expect(server.calls("x.operation").first?["request_id"] as? String == server.calls("x.accounts.verify").first?["request_id"] as? String)
}

@Test @MainActor func addingIsBlockedWithoutTheXKeyAndOnTheAdultSideWithoutAnAdultModelKey() async throws {
    let server = XBackend(xKey: false, adultModel: false)
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(!data.keyConfigured && !model.adultModelReady)
    #expect(FailureCopy.entry(for: BackendError(code: "credential_missing", domain: "x")).action == L10n.XAccounts.goConnect)
}

@Test func theAddFieldTellsAListLinkFromAUsername() {
    #expect(XAccountsData.entry("  @OpenAI ") == .handle("OpenAI"))
    #expect(XAccountsData.entry("https://x.com/karpathy") == .handle("karpathy"))
    #expect(XAccountsData.entry("https://x.com/i/lists/1234567890") == .list("https://x.com/i/lists/1234567890"))
    #expect(XAccountsData.entry("12345") == .handle("12345"))
    #expect(XAccountsData.entry("   ") == nil)
}

// MARK: - Alone or in the digest (§7.3)

@Test @MainActor func switchingSavesAtOnceAndTheDigestSummaryFollows() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1"), XBackend.account("a2", "sama", remote: "2")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    let digest = try #require(model.config?.xDigest("normal"))
    #expect(model.config?.aggregateAccounts(digest).count == 2)

    // Alone at 21:30 to the digest's Bots in the digest's style: both stay inherited.
    await data.sendAlone("a1", time: "21:30", bots: nil, style: nil, model: model)
    let route = try #require(server.calls("x.accounts.route").last)
    let overrides = try #require(route["overrides"] as? [String: Any])
    #expect(route["priority"] as? String == "special" && route["subscription_id"] as? String == "sub_x")
    #expect(overrides["times"] as? [String] == ["21:30"] && overrides["bot_ids"] is NSNull && overrides["style"] is NSNull)
    #expect(data.account("a1")?.sendsAlone == true)
    // The digests page reads the same configuration.
    let config = try #require(model.config)
    #expect(config.aggregateAccounts(digest).map(\.id) == ["a2"] && config.separateAccounts(digest).map(\.id) == ["a1"])

    // Own Bots are kept when they differ from the digest's.
    await data.sendAlone("a1", time: "07:00", bots: ["bot2", "bot1"], style: "source_image", model: model)
    #expect(server.stored("a1")?["bot_ids"] as? [String] == ["bot1", "bot2"] && server.stored("a1")?["times"] as? [String] == ["07:00"])

    await data.joinDigest("a1", model: model)
    #expect(server.stored("a1")?["priority"] as? String == "normal" && server.stored("a1")?["bot_ids"] as? [String] == [])
    #expect(model.config?.aggregateAccounts(digest).count == 2 && data.failures["route.a1"] == nil)
    #expect(data.savedAt["route.a1"] != nil)
}

@Test @MainActor func quickChangesToOneAccountSaveInTheOrderMade() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    // The first change's request is slow; without ordering, the second would be overwritten.
    server.delays["x.accounts.route"] = [.milliseconds(150)]
    async let first: Void = data.sendAlone("a1", time: "21:30", bots: nil, style: nil, model: model)
    try await Task.sleep(for: .milliseconds(20))
    async let second: Void = data.joinDigest("a1", model: model)
    _ = await (first, second)

    #expect(server.calls("x.accounts.route").map { $0["priority"] as! String } == ["special", "normal"])
    #expect(server.stored("a1")?["priority"] as? String == "normal")
}

@Test @MainActor func postTypesKeepAtLeastOneAndTheAccountsChoice() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.setPostType("a1", "replied_to", on: true, model: model)
    await data.setPostType("a1", "quoted", on: false, model: model)
    let route = try #require(server.calls("x.accounts.route").last)
    #expect(route["post_types"] as? [String] == ["original", "replied_to"] && route["priority"] as? String == "special")
    #expect(server.stored("a1")?["times"] as? [String] == ["21:30"])

    // Nothing to change sends nothing.
    await data.setPostType("a1", "original", on: true, model: model)
    #expect(server.calls("x.accounts.route").count == 2)
    #expect(typesText(["quoted", "original"], .zhHans) == "原帖 + 引用")
}

@Test @MainActor func aRefusedChangeIsShownOnTheAccount() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "night", partition: "adult", subscription: "sub_xa", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    // bot1 does not allow adult content.
    await data.sendAlone("a1", time: "23:00", bots: ["bot1"], style: nil, model: model)
    #expect(data.failures["route.a1"]?.code == "adult_permission_required")
    #expect(server.stored("a1")?["priority"] as? String == "normal")
    #expect(model.usableBots(for: "x_adult") == ["bot_adult"])
}

// MARK: - Kind of content (§7.3, §2.5)

@Test @MainActor func movingShowsTheImpactFirstAndThenJoinsTheOtherKindsDigest() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    let impact = try #require(await data.loadImpact("a1", model: model))
    #expect(impact.special && impact.specialBotIds == ["bot1"] && impact.cachedPosts == 4 && impact.pendingJobs == 1)
    #expect(server.calls("x.accounts.classify").isEmpty)

    #expect(await data.move("a1", to: "adult", impact: impact, model: model))
    #expect(server.calls("x.accounts.classify").first?["revision"] as? Int == impact.revision)
    let moved = try #require(server.stored("a1"))
    #expect(moved["partition"] as? String == "adult" && moved["subscription_id"] as? String == "sub_xa" && moved["priority"] as? String == "normal")
    #expect(data.accounts(in: "normal").isEmpty && data.accounts(in: "adult").map(\.id) == ["a1"])
}

@Test @MainActor func aChangeMadeAfterTheImpactWasShownShowsItAgainInsteadOfMoving() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    let impact = try #require(await data.loadImpact("a1", model: model))
    server.revision += 1  // e.g. a Telegram command changed the configuration meanwhile

    #expect(!(await data.move("a1", to: "adult", impact: impact, model: model)))
    #expect(data.failures["move.a1"]?.isConflict == true)
    #expect(server.stored("a1")?["partition"] as? String == "normal")
    #expect(data.impacts["a1"]?.revision == server.revision)
}

@Test @MainActor func removingTakesItsAlertRulesWithIt() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    server.alerts["enabled"] = true
    server.alerts["daily_limit"] = 3
    server.alerts["rules"] = [["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"]]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    #expect(await data.remove("a1", model: model))

    #expect(server.stored("a1") == nil)
    // Otherwise every later alert change would be refused (invalid_alert_scope).
    #expect((server.alerts["rules"] as! [[String: Any]]).isEmpty && server.alerts["enabled"] as? Bool == false)
}

@Test @MainActor func joiningTheDigestDropsRulesOnlyAnAccountSentAloneCanHave() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    server.alerts["rules"] = [
        ["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"],
        ["subscription_id": "sub_x", "account_id": NSNull(), "phrase": "outage"],
    ]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.joinDigest("a1", model: model)

    #expect((server.alerts["rules"] as! [[String: Any]]).map { $0["phrase"] as! String } == ["outage"])
    #expect(await data.addRule(XAlertRule(subscriptionId: "sub_x", accountId: nil, phrase: "recall"), model: model))
}

// MARK: - Lists

@Test @MainActor func aListIsReadAndItsMembersJoinTheDigestOfItsKind() async throws {
    let server = XBackend()
    server.listMembers["1234567890"] = [("alice", "101"), ("bob", "102")]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("https://x.com/i/lists/1234567890", partition: "normal", model: model)
    #expect(data.outcome == .list("1234567890"))
    #expect(server.calls("x.lists.add").first?["default_adult"] as? Bool == false)
    let list = try #require(data.lists.first)
    #expect(data.pending(list).count == 2 && data.accounts(in: "normal").isEmpty)

    await data.adoptMembers(list.id, model: model)
    #expect(data.outcome == nil)
    for handle in ["alice", "bob"] {
        let account = try #require(server.stored(handle: handle))
        #expect(account["partition"] as? String == "normal" && account["subscription_id"] as? String == "sub_x")
    }
    let adopted = try #require(data.lists.first)
    #expect(data.pending(adopted).isEmpty)
}

@Test @MainActor func newListMembersAreAskedAboutOneByOne() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "alice", remote: "101")])
    server.lists["555"] = ["id": "555", "partition": "normal", "default_adult": false, "name": "AI people", "state": "ready",
                           "members": [["account_id": "a1", "remote_id": "101"]], "checked_at": "2026-11-09T00:00:00+00:00"]
    server.listMembers["555"] = [("alice", "101"), ("carol", "103"), ("dave", "104")]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.refreshList("555", model: model)
    let list = try #require(data.lists.first)
    #expect(data.pending(list).map(\.handle).sorted() == ["carol", "dave"])

    let carol = try #require(server.stored(handle: "carol")?["id"] as? String)
    let dave = try #require(server.stored(handle: "dave")?["id"] as? String)
    await data.choose(carol, partition: "adult", model: model)
    await data.choose(dave, partition: nil, model: model)
    #expect(server.stored(carol)?["partition"] as? String == "adult" && server.stored(carol)?["subscription_id"] as? String == "sub_xa")
    let refreshed = try #require(data.lists.first)
    #expect(server.stored(dave)?["partition"] is NSNull && data.pending(refreshed).isEmpty)
    // Left out on this Mac only (the backend has no "ignored" state); nothing was saved for it.
    #expect(data.ignored.contains(dave) && server.calls("config.save").count == 1)
}

@Test @MainActor func aPrivateListIsNamed() async throws {
    let server = XBackend()
    server.privateLists = ["42"]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("https://x.com/i/lists/42", partition: "adult", model: model)
    guard case let .listFailed(failure, list) = data.outcome else { Issue.record("no failure"); return }
    #expect(list == "42")
    #expect(failure == BackendError(code: "private", domain: "x"))
    #expect(FailureCopy.message(for: failure, .en).contains("private"))
    #expect(server.calls("x.lists.add").first?["default_adult"] as? Bool == true)
}

// MARK: - Reads per day (§7.4)

@Test @MainActor func readsPerDayMatchTheBudgetsXMeter() async throws {
    let server = XBackend()
    let now = Date()
    let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
    let end = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
    server.periods = [["meter": "x", "start": start, "end": end, "timezone": "Asia/Tokyo", "known_settled": 84, "held": 0, "unpriced": 0,
                       "scopes": ["total": ["limit": 200, "used": 84, "remaining": 116], "partitions": ["normal": ["limit": 50, "used": 80], "adult": ["limit": NSNull(), "used": 4]]]]]
    server.budget["x"] = ["daily_limit": 200, "partition_limits": ["normal": 50, "adult": NSNull()], "account_limits": [String: Any](), "timezone": "Asia/Tokyo"]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    #expect(data.budget?.dailyReads == 200 && data.budget?.readsToday == 84)
    #expect(data.partitionLimit("normal")?.value == 50 && data.partitionLimit("normal")?.used == 80 && data.partitionLimit("adult") == nil)

    #expect(await data.saveDailyReads("300", model: model))
    #expect((server.budget["x"] as! [String: Any])["daily_limit"] as? Int == 300 && data.budget?.dailyReads == 300)
    #expect(await data.savePartitionReads("adult", "20", model: model))
    #expect(((server.budget["x"] as! [String: Any])["partition_limits"] as! [String: Any])["adult"] as? Int == 20)
    #expect(((server.budget["x"] as! [String: Any])["partition_limits"] as! [String: Any])["normal"] as? Int == 50)
    #expect(await data.saveDailyReads("", model: model))
    #expect((server.budget["x"] as! [String: Any])["daily_limit"] is NSNull)

    #expect(!(await data.saveDailyReads("12.5", model: model)))
    #expect(data.failures["budget.daily"]?.code == "invalid_count" && server.calls("budget.save").count == 3)
}

// MARK: - Advanced (§7.5)

@Test @MainActor func alertsNeedARuleAndTurnOnWithADailyLimit() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.setAlerts(true, model: model)
    #expect(data.failures["alerts"]?.code == "invalid_alert_rules" && server.alerts["enabled"] as? Bool == false)

    #expect(await data.addRule(XAlertRule(subscriptionId: "sub_x", accountId: "a1", phrase: "launch"), model: model))
    await data.setAlerts(true, model: model)
    #expect(server.alerts["enabled"] as? Bool == true && server.alerts["daily_limit"] as? Int == XAccountsData.defaultAlertsPerDay)
    #expect(data.alerts?.rules.first?.accountId == "a1")

    #expect(!(await data.addRule(XAlertRule(subscriptionId: "sub_x", accountId: "a1", phrase: "Launch"), model: model)))
    #expect(data.failures["alerts"]?.code == "duplicate_alert_rule")

    await data.removeRule(try #require(data.alerts?.rules.first), model: model)
    #expect(server.alerts["enabled"] as? Bool == false && (server.alerts["rules"] as! [[String: Any]]).isEmpty)
}

@Test @MainActor func videoChecksTurnOnWithBuiltInAmountsAndCheckOnRequest() async throws {
    let server = XBackend()
    server.candidates = [["job_id": "job1", "post_id": "99", "title": "Launch", "author": "openai", "request_id": NSNull()]]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    let models = XAccountsData.videoModels(model.config)
    #expect(models.vision == ["normal_primary"] && models.speech == ["normal_primary"])

    await data.setVideo(true, model: model)
    #expect(server.video["enabled"] as? Bool == true && server.video["daily_model_limit"] as? Int == 1_000_000)
    #expect(server.video["vision_profiles"] as? [String] == ["normal_primary"] && server.video["stt_hold"] as? Int == 50_000)
    #expect(data.candidates.count == 1)

    #expect(!(await data.saveVideoBudget("0", model: model)))
    #expect(data.failures["video.budget"]?.code == "invalid_video_amount")
    #expect(await data.saveVideoBudget("3", model: model))
    #expect(server.video["daily_model_limit"] as? Int == 3_000_000)

    await data.inspect(try #require(data.candidates.first), model: model)
    #expect(data.inspections["job1/99"]?.transcript == "hello" && data.candidates.first?.requestId != nil)

    await data.setVideo(false, model: model)
    #expect(server.video["enabled"] as? Bool == false && server.video["daily_model_limit"] as? Int == 3_000_000)
}

// MARK: - Shapes, words and the overview (R08-26)

@Test func accountStatesHaveTheirOwnWordsAndColours() {
    let states = ["ready", "protected", "unavailable", "invalidated", "credential_changed", "permission_denied", "authentication_failed", "unverified", "identity_mismatch"]
    let mapped = states.map(XAccountState.init)
    #expect(mapped == [.readable, .protected, .gone, .gone, .recheck, .noPermission, .keyRejected, .unverified, .recheck])
    for language in AppLanguage.allCases {
        #expect(Set(Set(mapped).map { $0.words(language) }).count == Set(mapped).count)
    }
    #expect(XOperationReply(state: "budget_blocked", reason: "partition_limit", retryAfter: nil, account: nil, canonicalAccountId: nil, list: nil).failure?.code == "partition_limit")
    #expect(XOperationReply(state: "ready", reason: nil, retryAfter: nil, account: nil, canonicalAccountId: nil, list: nil).failure == nil)
}

@Test func xCopyHasAllLanguagesAndAvoidsInternalWords() {
    let banned = ["subscription", "route", "target", "priority", "special", "include_in_aggregate", "partition", "revision", "订阅", "路由", "特别关注", "分区"]
    for words in L10n.XAccounts.all {
        for language in AppLanguage.allCases {
            let text = words(language)
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty)
            for word in banned { #expect(!text.lowercased().contains(word), "\(word) in \(text)") }
        }
        #expect(words.zh != words.en)
    }
    let codes = [
        "x.authentication_failed", "x.permission_denied", "x.credential_missing", "x.rate_limited", "x.outcome_unknown", "x.unavailable",
        "x.private", "x.partial", "x.account_limit", "x_still_running", "x_limit", "partition_limit", "account_limit", "operation_busy",
        "missing_account", "invalid_handle", "invalid_list", "list_conflict", "list_limit", "incompatible_subscription",
        "invalid_alert_rules", "duplicate_alert_rule", "invalid_alert_scope", "invalid_video_profiles", "video_daily_budget",
    ]
    for code in codes { #expect(FailureCopy.table[code] != nil, "no copy for \(code)") }
    // X's 401 and 403 send the owner to the X key, not to a model key.
    for code in ["authentication_failed", "permission_denied"] {
        #expect(FailureCopy.message(for: BackendError(code: code, domain: "x"), .en) != FailureCopy.message(for: BackendError(code: code, domain: "models"), .en))
    }
}

@Test @MainActor func overviewRowsOfAnAccountSentAloneNameItsOwnBots() async throws {
    let server = XBackend(accounts: [
        XBackend.account("own", "elonmusk", priority: "special", remote: "1", times: ["21:30"], bots: ["bot2"]),
        XBackend.account("inherit", "karpathy", priority: "special", remote: "2", times: ["09:00"]),
        XBackend.account("plain", "sama", remote: "3"),
    ])
    let (model, _, cleanup) = try await connected(server)
    defer { cleanup() }

    #expect(model.recipients("sub_x", accountId: "own") == ["bot2"])
    #expect(model.recipients("sub_x", accountId: "inherit") == ["bot1"])
    #expect(model.recipients("sub_x", accountId: "plain") == ["bot1"])
    #expect(model.recipients("sub_x", accountId: nil) == ["bot1"])
    #expect(model.targetsLine("sub_x", accountId: "own") == "→ @bot2")
    #expect(model.targetsLine("sub_x") == "→ @bot1")
    #expect(model.editionTitle("sub_x", accountId: "own").hasSuffix("@elonmusk"))

    // A planned slot of the account (not created by the scheduler yet) goes to its own Bot.
    let slots = OverviewData.upcoming(try #require(model.config).subscriptions, accounts: try #require(model.config).accounts, existing: [],
                                      now: Date())
    for slot in slots where slot.accountId == "own" { #expect(model.targetsLine(slot.subscriptionId, accountId: slot.accountId) == "→ @bot2") }
}

// MARK: - Review cycle 1

@Test @MainActor func adoptingAnAdultListJoinsItsMembersToTheAdultDigest() async throws {
    let server = XBackend()
    server.listMembers["777"] = [("night_a", "201"), ("night_b", "202")]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("https://x.com/i/lists/777", partition: "adult", model: model)
    #expect(data.outcome == .list("777"))
    // The backend makes adult List members adult right away, but in no digest yet.
    let list = try #require(data.lists.first)
    #expect(data.pending(list).isEmpty && data.notInDigest(list).count == 2)
    #expect(data.accounts(in: "adult").allSatisfy { !$0.inDigest && !$0.sendsAlone })

    await data.adoptMembers("777", model: model)
    for handle in ["night_a", "night_b"] {
        let account = try #require(server.stored(handle: handle))
        #expect(account["partition"] as? String == "adult" && account["subscription_id"] as? String == "sub_xa")
    }
    let adopted = try #require(data.lists.first)
    #expect(data.notInDigest(adopted).isEmpty && data.accounts(in: "adult").allSatisfy(\.inDigest))
    #expect(data.outcome == nil && data.accounts(in: "normal").isEmpty)
}

@Test @MainActor func aDraftWhoseDigestChoiceFailedJoinsItOnRetry() async throws {
    let server = XBackend()
    server.users["sama"] = .init(remote: "5")
    server.failNext["x.accounts.route"] = "storage_failed"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("sama", partition: "normal", model: model)
    let id = try #require(server.stored(handle: "sama")?["id"] as? String)
    guard case let .failed(_, draft) = data.outcome else { Issue.record("no failure"); return }
    #expect(draft == id && server.stored(id)?["subscription_id"] is NSNull)
    #expect(data.account(id)?.inDigest == false)

    await data.retryAdd(id, partition: "normal", model: model)
    #expect(server.stored(id)?["subscription_id"] as? String == "sub_x" && data.outcome == .added(id))
    #expect(data.account(id)?.inDigest == true)
}

@Test @MainActor func anAccountInNoDigestJoinsItFromTheRow() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "sama", subscription: nil, remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(data.account("a1")?.inDigest == false && data.account("a1")?.sendsAlone == false)

    await data.joinDigest("a1", model: model)
    #expect(server.stored("a1")?["subscription_id"] as? String == "sub_x" && data.account("a1")?.inDigest == true)
}

@Test @MainActor func aMoveWhoseDigestChoiceFailedCanBeRetried() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    let impact = try #require(await data.loadImpact("a1", model: model))
    server.failNext["x.accounts.route"] = "storage_failed"
    #expect(await data.move("a1", to: "adult", impact: impact, model: model))
    #expect(server.stored("a1")?["partition"] as? String == "adult" && server.stored("a1")?["subscription_id"] is NSNull)
    #expect(data.failures["route.a1"]?.code == "storage_failed")

    await data.retryRoute("a1", model: model)
    #expect(server.stored("a1")?["subscription_id"] as? String == "sub_xa" && data.failures["route.a1"] == nil)
}

@Test @MainActor func joiningTheDigestAsksFirstOnlyWhenRulesWouldGo() async throws {
    let server = XBackend(accounts: [
        XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"]),
        XBackend.account("a2", "karpathy", priority: "special", remote: "2", times: ["09:00"]),
    ])
    server.alerts["rules"] = [["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"]]
    let (_, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(data.rulesOn("a1") == 1 && data.rulesOn("a2") == 0)
}

@Test @MainActor func aFailedListReadCanBeReadAgain() async throws {
    let server = XBackend()
    server.listMembers["888"] = [("alice", "101")]
    server.readFailure = "rate_limited"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("https://x.com/i/lists/888", partition: "normal", model: model)
    #expect(data.outcome == .listFailed(BackendError(code: "rate_limited", domain: "x"), "888"))

    server.readFailure = nil
    await data.retryList("888", model: model)
    #expect(data.outcome == .list("888") && server.calls("x.lists.refresh").count == 2)
}

@Test @MainActor func twoQuickPostTypeChangesBothStick() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    server.delays["x.accounts.route"] = [.milliseconds(150)]
    async let first: Void = data.setPostType("a1", "replied_to", on: true, model: model)
    try await Task.sleep(for: .milliseconds(20))
    async let second: Void = data.setPostType("a1", "retweeted", on: true, model: model)
    _ = await (first, second)
    #expect(server.stored("a1")?["post_types"] as? [String] == XPostType.all)

    // The last kind cannot be turned off.
    await data.setPostType("a1", "original", on: false, model: model)
    await data.setPostType("a1", "quoted", on: false, model: model)
    await data.setPostType("a1", "replied_to", on: false, model: model)
    await data.setPostType("a1", "retweeted", on: false, model: model)
    #expect(server.stored("a1")?["post_types"] as? [String] == ["retweeted"])
}

@Test @MainActor func todaysPostsAreCountedRarelyAndWithASmallLimit() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1"), XBackend.account("a2", "sama", remote: "2")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(server.calls("x.posts.list").count == 2)
    #expect(server.calls("x.posts.list").allSatisfy { ($0["limit"] as? Int ?? 0) <= XAccountsData.postsLimit })

    // The 10-second page refresh does not count them again.
    await data.load(model: model)
    await data.load(model: model)
    #expect(server.calls("x.posts.list").count == 2)
    #expect(FailureCopy.table["x.partial_response"] != nil)
}

// MARK: - Review cycle 2

@Test @MainActor func aFailedQueuedChangeIsRetriedAsItselfNeverAsJoiningTheDigest() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", remote: "1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    // The first change (send alone) is slow and succeeds; the queued second one fails.
    server.delays["x.accounts.route"] = [.milliseconds(150)]
    server.refuseWhen = { $0["op"] as? String == "x.accounts.route" && $0["post_types"] != nil ? "storage_failed" : nil }
    async let first: Void = data.sendAlone("a1", time: "21:30", bots: nil, style: nil, model: model)
    try await Task.sleep(for: .milliseconds(20))
    async let second: Void = data.setPostType("a1", "replied_to", on: true, model: model)
    _ = await (first, second)
    #expect(server.stored("a1")?["priority"] as? String == "special" && data.failures["route.a1"]?.code == "storage_failed")
    #expect(data.canRetryRoute("a1"))

    server.refuseWhen = nil
    await data.retryRoute("a1", model: model)
    // The post types were sent again; the account is still sent alone.
    #expect(server.stored("a1")?["priority"] as? String == "special")
    #expect(server.stored("a1")?["post_types"] as? [String] == ["original", "quoted", "replied_to"])
    #expect(data.failures["route.a1"] == nil && !data.canRetryRoute("a1"))
    // Nothing failed now: there is nothing to retry, and retrying changes nothing.
    let sent = server.calls("x.accounts.route").count
    await data.retryRoute("a1", model: model)
    #expect(server.calls("x.accounts.route").count == sent)
}

@Test @MainActor func anAccountTheBackendAlreadyHasIsNotRoutedOrReadAgain() async throws {
    let server = XBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    // Added elsewhere after the page last read the directory.
    server.document["accounts"] = [XBackend.account("a2", "night", partition: "adult", subscription: "sub_xa", remote: "2")]
    server.revision += 1
    await data.add("night", partition: "normal", model: model)
    #expect(data.outcome == .otherPartition("night", "adult"))

    server.document["accounts"] = server.accounts + [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])]
    server.revision += 1
    await data.add("elonmusk", partition: "normal", model: model)
    #expect(data.outcome == .exists("a1") && data.highlighted == "a1")
    #expect(server.calls("x.accounts.add").count == 2)
    #expect(server.calls("x.accounts.route").isEmpty && server.calls("x.accounts.verify").isEmpty)
    #expect(server.stored("a1")?["priority"] as? String == "special" && server.stored("a2")?["partition"] as? String == "adult")
}

@Test @MainActor func aDraftThatCouldNotBeRemovedIsSaidAndRemovedOnRetry() async throws {
    let server = XBackend()
    server.failNext["x.accounts.remove"] = "storage_failed"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.add("nobody_here", partition: "normal", model: model)
    let draft = try #require(server.stored(handle: "nobody_here")?["id"] as? String)
    guard case let .cleanupFailed(failure, id, after) = data.outcome else { Issue.record("no cleanup failure: \(String(describing: data.outcome))"); return }
    #expect(failure.code == "storage_failed" && id == draft && after == .missing("nobody_here"))

    await data.retryCleanup(model: model)
    #expect(server.stored(draft) == nil && data.outcome == .missing("nobody_here"))
}

@Test @MainActor func aFailedRuleCleanupIsShownAndCanBeRetried() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"])])
    server.alerts["rules"] = [["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"]]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    server.failNext["x.alerts.save"] = "storage_failed"
    #expect(await data.remove("a1", model: model))
    #expect(server.stored("a1") == nil && data.failures["rules"]?.code == "storage_failed")
    #expect((server.alerts["rules"] as! [[String: Any]]).count == 1)

    await data.retryRuleCleanup(model: model)
    #expect(data.failures["rules"] == nil && (server.alerts["rules"] as! [[String: Any]]).isEmpty)
}

@Test @MainActor func aListNoteSaysAllMembersAreInOnlyWhenTheyAre() async throws {
    let server = XBackend(accounts: [XBackend.account("a1", "alice", remote: "101"), XBackend.account("a2", "carol", partition: nil, subscription: nil, remote: "103")])
    server.lists["555"] = ["id": "555", "partition": "normal", "default_adult": false, "name": "AI people", "state": "ready",
                           "members": [["account_id": "a1", "remote_id": "101"], ["account_id": "a2", "remote_id": "103"]], "checked_at": "2026-11-09T00:00:00+00:00"]
    let (_, data, cleanup) = try await connected(server)
    defer { cleanup() }
    let list = try #require(data.lists.first)
    #expect(data.listNote(list) == L10n.XAccounts.listNotePending)
}

// MARK: - Review cycle 3

@Test @MainActor func ruleImpactIsUnknownUntilThePolicyIsReadAndIsReadBeforeActing() async throws {
    let server = XBackend(accounts: [
        XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"]),
        XBackend.account("a2", "karpathy", priority: "special", remote: "2", times: ["09:00"]),
    ])
    server.alerts["rules"] = [
        ["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"],
        ["subscription_id": "sub_x", "account_id": "a2", "phrase": "agents"],
    ]
    server.refuseWhen = { $0["op"] as? String == "x.alerts.status" ? "storage_failed" : nil }
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    // Not read: unknown, not "no rules"; and an unreadable policy is said where the action is.
    #expect(data.rulesOn("a1") == nil)
    #expect(await data.rulesBeforeChange("a1", key: "route.a1", model: model) == nil)
    #expect(data.failures["route.a1"]?.code == "storage_failed")

    // Unreadable when the cleanup runs: said, with a retry, never skipped.
    #expect(await data.remove("a1", model: model))
    #expect(data.failures["rules"]?.code == "storage_failed" && (server.alerts["rules"] as! [[String: Any]]).count == 2)

    server.refuseWhen = nil
    // Read before a confirmation is shown.
    #expect(await data.rulesBeforeChange("a2", key: "route.a2", model: model) == 1)
    await data.retryRuleCleanup(model: model)
    #expect(data.failures["rules"] == nil)
    #expect((server.alerts["rules"] as! [[String: Any]]).map { $0["phrase"] as! String } == ["agents"])
}

@Test @MainActor func ruleCleanupTouchesOnlyTheChangedAccountsRules() async throws {
    let server = XBackend(accounts: [
        XBackend.account("a1", "elonmusk", priority: "special", remote: "1", times: ["21:30"]),
        XBackend.account("a2", "karpathy", remote: "2"),
    ])
    server.alerts["rules"] = [["subscription_id": "sub_x", "account_id": "a1", "phrase": "launch"]]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    // While a1 is removed, another writer sends a2 alone and gives it a rule.
    server.beforeAlertsSave = { server in
        server.document["accounts"] = server.accounts.map { entry in
            guard entry["id"] as? String == "a2" else { return entry }
            var entry = entry
            entry["priority"] = "special"
            entry["bot_ids"] = NSNull()
            return entry
        }
        server.revision += 1
        server.alerts["rules"] = (server.alerts["rules"] as! [[String: Any]]) + [["subscription_id": "sub_x", "account_id": "a2", "phrase": "agents"]]
        server.alertsRevision += 1
    }
    #expect(await data.remove("a1", model: model))
    #expect((server.alerts["rules"] as! [[String: Any]]).map { $0["phrase"] as! String } == ["agents"])
}

@Test @MainActor func turningVideoOnOrOffReplacesModelsThatCanNoLongerDoIt() async throws {
    let server = XBackend()
    server.video["vision_profiles"] = ["old_model"]
    server.video["stt_profiles"] = ["old_model"]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.setVideo(true, model: model)
    #expect(data.failures["video"] == nil && server.video["enabled"] as? Bool == true)
    #expect(server.video["vision_profiles"] as? [String] == ["normal_primary"] && server.video["stt_profiles"] as? [String] == ["normal_primary"])

    server.video["vision_profiles"] = ["old_model", "normal_primary"]
    await data.setVideo(false, model: model)
    #expect(data.failures["video"] == nil && server.video["enabled"] as? Bool == false)
    #expect(server.video["vision_profiles"] as? [String] == ["normal_primary"])
}

@Test @MainActor func addingWaitsUntilAnXKeyIsKnown() async throws {
    #expect(!XAccountsData().keyConfigured)
    let server = XBackend()
    server.failNext["x.accounts.list"] = "storage_failed"
    let name = "NewsPawXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(client: server.client, defaults: defaults)
    await model.refresh()
    let data = XAccountsData(defaults: defaults)
    await data.load(model: model)
    #expect(!data.keyConfigured && data.failures["load"] != nil)
    await data.load(model: model)
    #expect(data.keyConfigured)
}
