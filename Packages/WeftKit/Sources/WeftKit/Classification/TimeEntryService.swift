import Foundation
import Observation
import SwiftData

/// Writes a one-sentence description of each finished time entry with the on-device model,
/// one at a time in the background, and keeps them in the store.
@MainActor
@Observable
public final class TimeEntryService {
    public private(set) var descriptions: [String: String] = [:]

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let ai: any AIClassifying
    @ObservationIgnored private var queue: [(key: String, facts: String)] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Descriptions are stored per language, so after the user switches, each entry is described again.
    @ObservationIgnored private let language = OutputLanguage.name()

    public init(modelContext: ModelContext, ai: any AIClassifying) {
        self.modelContext = modelContext
        self.ai = ai
        let records = (try? modelContext.fetch(FetchDescriptor<TimeEntrySummary>())) ?? []
        descriptions = Dictionary(records.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
    }

    /// Descriptions written before they were stored per language keep the bare `TimeEntry.key`.
    /// They still count, in whatever language they were written, so nothing is asked again.
    public func description(for entry: TimeEntry) -> String? {
        descriptions[storageKey(entry)] ?? descriptions[entry.key]
    }

    /// `TimeEntry.key` plus the language, e.g. `code-1767225600|English (United States)`.
    private func storageKey(_ entry: TimeEntry) -> String {
        "\(entry.key)|\(language)"
    }

    /// Queues every finished entry that has no description yet.
    public func describe(_ entries: [TimeEntry], now: Date = .now) {
        guard ai.availability() == .available else { return }
        for entry in entries where entry.isComplete(now: now) {
            let key = storageKey(entry)
            guard description(for: entry) == nil, !failed.contains(key), !queue.contains(where: { $0.key == key }) else { continue }
            queue.append((key, entry.facts))
        }
        if worker == nil, !queue.isEmpty {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    /// Today's entries, for the periodic background pass.
    public func describeToday() {
        let start = Calendar.current.startOfDay(for: .now)
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.end > start }, sortBy: [SortDescriptor(\.start)]
        ))) ?? []
        describe(TimeEntries.significant(TimeEntries.build(segments)))
    }

    private func drain() async {
        while let next = queue.first {
            do {
                let text = try await ai.describeActivity(next.facts, language: language)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                descriptions[next.key] = text
                modelContext.insert(TimeEntrySummary(key: next.key, text: text))
                try? modelContext.save()
            } catch {
                failed.insert(next.key)
            }
            queue.removeFirst()
        }
        worker = nil
    }
}
