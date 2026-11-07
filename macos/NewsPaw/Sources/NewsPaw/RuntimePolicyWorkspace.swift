import Foundation
import SwiftUI

private enum RuntimeEditor: String, Identifiable {
    case budget, schedule, style
    var id: String { rawValue }
}

struct RuntimePolicyWorkspace: View {
    let model: AppModel
    @State private var editor: RuntimeEditor?

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label(.policy)).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .sheet(item: $editor) { RuntimePolicyEditor(model: model, kind: $0) }
    }

    @ViewBuilder private var actions: some View {
        Button(label(.budget)) { editor = .budget }
        Button(label(.schedule)) { editor = .schedule }
        Button(SubscriptionCopy.style.text(model.uiLanguage)) { editor = .style }
    }
}

private struct BudgetReport: Decodable {
    struct Split: Decodable {
        let knownSettled, held: Int
        let knownBySource: [String: Int]
    }
    struct Period: Decodable, Identifiable {
        let id: Int
        let start, end, meter: String
        let knownSettled, held: Int
        let remaining: Int?
        let operations: [String: Split]?
    }
    struct Report: Decodable { let periods: [Period] }
    let report: Report
}

private struct RuntimePolicyEditor: View {
    let model: AppModel
    let kind: RuntimeEditor
    @Environment(\.dismiss) private var dismiss
    @State private var document: [String: Any] = [:]
    @State private var report: [BudgetReport.Period] = []
    @State private var revision = 0
    @State private var modelLimit = ""
    @State private var imageLimit = ""
    @State private var xLimit = ""
    @State private var normalHold = ""
    @State private var adultHold = ""
    @State private var ordinaryStyle = "text"
    @State private var adultStyle = "text"
    @State private var scheduled = false
    @State private var failure: Phrase?
    @State private var busy = false

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack {
            Form {
                switch kind {
                case .budget:
                    Section(label(.budget)) {
                        TextField(label(.modelLimit), text: $modelLimit)
                        TextField(label(.imageLimit), text: $imageLimit)
                        TextField(label(.xLimit), text: $xLimit)
                    }
                    ForEach(report) { period in
                        Section(period.meter == "x" ? label(.xLimit) : label(.budget)) {
                            Text(period.start + " – " + period.end).font(.caption)
                            if let remaining = period.remaining {
                                Text(label(.remaining) + " · " + formatted(remaining, meter: period.meter))
                            }
                            ForEach(period.meter == "x" ? ["x"] : ["text", "search", "image"], id: \.self) { key in
                                if let split = period.operations?[key] {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(operation(key))
                                        Text(label(.settled) + " " + formatted(split.knownSettled, meter: period.meter) + " · " + label(.reserved) + " " + formatted(split.held, meter: period.meter))
                                        let reported = split.knownBySource["reported"] ?? 0
                                        let derived = split.knownBySource["usage_derived"] ?? 0
                                        if reported > 0 || derived > 0 {
                                            Text(label(.reported) + " " + formatted(reported, meter: period.meter) + " · " + label(.estimated) + " " + formatted(derived, meter: period.meter))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                case .schedule:
                    Section(label(.schedule)) {
                        Toggle(label(.automatic), isOn: $scheduled)
                        TextField(label(.normalHold), text: $normalHold)
                        TextField(label(.adultHold), text: $adultHold)
                    }
                case .style:
                    stylePicker(model.text(.ordinary), selection: $ordinaryStyle)
                    stylePicker(model.text(.adult), selection: $adultStyle)
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(revision == 0 || busy)
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(label(.save)) { Task { await save() } }.disabled(revision == 0 || busy)
            }.padding()
        }
        .frame(minWidth: 620, minHeight: 440)
        .task { await load() }
    }

    private func stylePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(SubscriptionCopy.textStyle.text(model.uiLanguage)).tag("text")
            Text(SubscriptionCopy.imageStyle.text(model.uiLanguage)).tag("source_image")
            Text(SubscriptionCopy.newspaperStyle.text(model.uiLanguage)).tag("newspaper")
        }
    }

    private func operation(_ value: String) -> String {
        switch value {
        case "image": label(.image)
        case "search": label(.search)
        case "x": "X"
        default: label(.text)
        }
    }

    private func formatted(_ amount: Int, meter: String) -> String {
        if meter == "x" { return amount.formatted() }
        let usd = Decimal(amount) / Decimal(1_000_000)
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
    }

    private func integer(_ raw: String) throws -> Any {
        if raw.isEmpty { return NSNull() }
        guard let value = boundedUnits(raw) else { throw BackendFailure.rejected }
        return value
    }

    private func visiblePeriods(_ periods: [BudgetReport.Period]) -> [BudgetReport.Period] {
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let now = Date()
        return periods.filter { period in
            guard let start = fractional.date(from: period.start) ?? whole.date(from: period.start),
                  let end = fractional.date(from: period.end) ?? whole.date(from: period.end) else { return false }
            return start <= now && now < end
        }
    }

    private func load() async {
        do {
            let operation = kind == .budget ? "budget.get" : kind == .schedule ? "schedule.status" : "config.get"
            let data = try await model.request(operation)
            let state: SettingsRevision = try BackendRPC.decode(data)
            document = try ProtectedSettings.record(data, revision: state.revision, field: kind == .schedule ? "settings" : "document")
            revision = state.revision
            if kind == .budget {
                let usage: BudgetReport = try BackendRPC.decode(data)
                report = visiblePeriods(usage.report.periods)
                let model = document["model"] as? [String: Any] ?? [:]
                let x = document["x"] as? [String: Any] ?? [:]
                modelLimit = (model["monthly_limit"] as? Int).map(String.init) ?? ""
                imageLimit = (model["image_limit"] as? Int).map(String.init) ?? ""
                xLimit = (x["daily_limit"] as? Int).map(String.init) ?? ""
            } else if kind == .schedule {
                scheduled = document["enabled"] as? Bool ?? false
                let holds = document["holds"] as? [String: Any] ?? [:]
                normalHold = (holds["normal"] as? Int).map(String.init) ?? ""
                adultHold = (holds["adult"] as? Int).map(String.init) ?? ""
            } else {
                let styles = document["group_styles"] as? [String: String] ?? [:]
                ordinaryStyle = styles["normal"] ?? "text"
                adultStyle = styles["adult"] ?? "text"
            }
        } catch { failure = .saveFailed }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            var next = document
            switch kind {
            case .budget:
                guard var model = next["model"] as? [String: Any], var x = next["x"] as? [String: Any] else {
                    throw BackendFailure.invalidReply
                }
                model["monthly_limit"] = try integer(modelLimit)
                model["image_limit"] = try integer(imageLimit)
                x["daily_limit"] = try integer(xLimit)
                next["model"] = model
                next["x"] = x
                _ = try await self.model.request("budget.save", fields: ["revision": revision, "document": next])
            case .schedule:
                let normal = try integer(normalHold)
                let adult = try integer(adultHold)
                guard !scheduled || (normal as? Int ?? 0) > 0 || (adult as? Int ?? 0) > 0 else {
                    throw BackendFailure.rejected
                }
                next["enabled"] = scheduled
                next["holds"] = ["normal": normal, "adult": adult]
                _ = try await model.request("schedule.configure", fields: ["revision": revision, "settings": next])
            case .style:
                next["group_styles"] = ["normal": ordinaryStyle, "adult": adultStyle]
                _ = try await model.request("config.save", fields: ["revision": revision, "document": next])
            }
            await model.refresh()
            dismiss()
        } catch BackendFailure.conflict { failure = .conflict }
        catch { failure = .saveFailed }
    }
}
