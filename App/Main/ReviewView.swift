import WeftKit
import SwiftData
import SwiftUI

/// Apps and sites no rule knew: still waiting for the model, or classified by it and not yet
/// confirmed. Confirming or changing one creates a rule, which takes it off this list.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let pending = ClassificationSource.pending.rawValue
        let ai = ClassificationSource.ai.rawValue
        _segments = Query(filter: #Predicate<ActivitySegment> {
            $0.end > since && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == ai)
        })
    }

    private struct Item: Identifiable {
        var key: String
        var sample: ActivitySegment
        var duration: TimeInterval
        var categoryKey: String
        var source: ClassificationSource
        var confidence: AIConfidence?
        var id: String { key }
    }

    var body: some View {
        let items = items()
        VStack(spacing: 0) {
            statusBar
            Divider()
            if items.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                       description: Text("Every app and site from the last 30 days is covered by a rule."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(items) {
                    TableColumn("App / Site") { item in
                        HStack {
                            Image(nsImage: AppIcons.icon(for: item.sample.bundleID)).resizable().frame(width: 16, height: 16)
                            VStack(alignment: .leading) {
                                Text(item.sample.domain ?? item.sample.appName)
                                if item.sample.domain != nil {
                                    Text(item.sample.appName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    TableColumn("Time (30 days)") { item in
                        Text(Format.duration(item.duration)).monospacedDigit()
                    }
                    .width(110)
                    TableColumn("Status") { item in
                        switch item.source {
                        case .pending: Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
                        default: Text("AI · \(item.confidence?.rawValue ?? "?") confidence").foregroundStyle(.secondary)
                        }
                    }
                    .width(160)
                    TableColumn("Category") { item in
                        Picker("", selection: Binding(
                            get: { item.categoryKey },
                            set: { assign(item, to: $0) }
                        )) {
                            ForEach(model.classifier.categories) { category in
                                Text(category.name).tag(category.key)
                            }
                        }
                        .labelsHidden()
                    }
                    .width(180)
                    TableColumn("") { item in
                        Button {
                            assign(item, to: item.categoryKey)
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.source == .pending)
                        .help("Looks right — keep \(model.classifier.category(item.categoryKey).name) for this app/site")
                    }
                    .width(30)
                }
            }
        }
        .navigationTitle("Review")
        .toolbar {
            let confident = items.filter { $0.source == .ai && $0.confidence == .high }
            Button {
                for item in confident { assign(item, to: item.categoryKey) }
            } label: {
                Label("Confirm \(confident.count) High-Confidence", systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(confident.isEmpty)
            .help("Keep the model's category for every app and site it was sure about")
        }
    }

    private var statusBar: some View {
        HStack {
            switch model.classifier.aiAvailability {
            case .available:
                Image(systemName: "sparkles")
                Text(model.classifier.queuedCount > 0
                     ? "Classifying \(model.classifier.queuedCount) app(s)/site(s) on device…"
                     : "On-device classification is on.")
                if model.classifier.queuedCount > 0 { ProgressView().controlSize(.small) }
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason)
                Button("Open Settings") { SystemSettings.openAppleIntelligence() }
            }
            Spacer()
            Button("Retry") { model.classifier.retryPending() }
                .help("Ask the model again about everything still waiting")
        }
        .font(.callout)
        .padding(12)
    }

    private func items() -> [Item] {
        var byKey: [String: Item] = [:]
        for segment in segments {
            let key = segment.classificationKey
            if var item = byKey[key] {
                item.duration += segment.duration
                byKey[key] = item
            } else {
                byKey[key] = Item(key: key, sample: segment, duration: segment.duration, categoryKey: segment.categoryKey,
                                  source: segment.classificationSource, confidence: model.classifier.confidence(forKey: key))
            }
        }
        // Waiting first, then least confident, then most time spent.
        func rank(_ item: Item) -> Int {
            switch (item.source, item.confidence) {
            case (.pending, _): 0
            case (_, .low?), (_, nil): 1
            case (_, .medium?): 2
            case (_, .high?): 3
            }
        }
        return byKey.values.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.duration > b.duration
        }
    }

    private func assign(_ item: Item, to categoryKey: String) {
        if let domain = item.sample.domain {
            model.classifier.addRule(field: .domain, pattern: domain, categoryKey: categoryKey)
        } else {
            model.classifier.addRule(field: .bundleID, pattern: item.sample.bundleID, categoryKey: categoryKey)
        }
    }
}
