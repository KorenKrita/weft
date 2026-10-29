import WeftKit
import SwiftData
import SwiftUI

/// Apps and sites no rule knew: still waiting for the model, guessed without one, or
/// classified by it and not yet confirmed. Confirming or changing one creates a rule, which
/// takes it off this list.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let pending = ClassificationSource.pending.rawValue
        let guess = ClassificationSource.guess.rawValue
        let ai = ClassificationSource.ai.rawValue
        _segments = Query(filter: #Predicate<ActivitySegment> {
            $0.end > since && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == guess
                || $0.classificationSourceRaw == ai)
        })
    }

    private struct Item: Identifiable {
        var key: String
        var sample: ActivitySegment
        var duration: TimeInterval
        var categoryKey: String
        var source: ClassificationSource
        var confidence: AIConfidence?
        /// The most used window or page titles, so it's clear what the app or site was used for.
        var titles: [String] = []
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
                                if !item.titles.isEmpty {
                                    Text(item.titles.prefix(2).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else if item.sample.domain != nil {
                                    Text(item.sample.appName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .help(item.titles.joined(separator: "\n"))
                        }
                    }
                    TableColumn("Time (30 days)") { item in
                        Text(Format.duration(item.duration)).monospacedDigit()
                    }
                    .width(110)
                    TableColumn("Status") { item in
                        switch item.source {
                        case .pending: Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
                        case .guess: Label("Guess", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                        default: Text("AI · \(item.confidence.map { String(localized: String.LocalizationValue($0.rawValue)) } ?? "?") confidence").foregroundStyle(.secondary)
                        }
                    }
                    .width(160)
                    TableColumn("Category") { item in
                        Picker("", selection: Binding(
                            get: { item.categoryKey },
                            set: { assign(item, to: $0) }
                        )) {
                            ForEach(model.classifier.categories) { category in
                                Text(category.displayName).tag(category.key)
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
                        .help("Looks right — keep \(model.classifier.category(item.categoryKey).displayName) for this app/site")
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
                let queued = model.classifier.queuedCount
                Image(systemName: "sparkles")
                Text(queued > 0
                     ? "Classifying \(queued) app(s)/site(s) \(model.modelPlace)…"
                     : "Unknown apps and sites are classified \(model.modelPlace).")
                if queued > 0 { ProgressView().controlSize(.small) }
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("\(reason) Weft guesses from each app's App Store category and each site's name until a model is available.")
                SettingsLink { Text("Model Settings…") }
            }
            Spacer()
            Button("Retry") { model.classifier.retryPending() }
                .help("Ask the model again about everything still waiting or guessed")
        }
        .font(.callout)
        .padding(12)
    }

    private func items() -> [Item] {
        var byKey: [String: Item] = [:]
        var titles: [String: [(title: String?, duration: TimeInterval)]] = [:]
        for segment in segments {
            let key = segment.classificationKey
            titles[key, default: []].append((segment.title, segment.duration))
            if var item = byKey[key] {
                item.duration += segment.duration
                byKey[key] = item
            } else {
                byKey[key] = Item(key: key, sample: segment, duration: segment.duration, categoryKey: segment.categoryKey,
                                  source: segment.classificationSource, confidence: model.classifier.confidence(forKey: key))
            }
        }
        for (key, samples) in titles {
            guard let appName = byKey[key]?.sample.appName else { continue }
            byKey[key]?.titles = TitleSummary.mostUsed(samples, appName: appName, limit: 3)
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
