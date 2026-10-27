import Foundation
import SwiftData

/// Idempotent fix-ups of stored data, run at launch.
@MainActor
public enum Maintenance {
    public static func run(modelContext: ModelContext, classifier: ClassificationService,
                           ownBundleID: String? = Bundle.main.bundleIdentifier) {
        // Time spent in OpenRize itself used to be recorded.
        if let ownBundleID {
            let own = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.bundleID == ownBundleID }))) ?? []
            for segment in own { modelContext.delete(segment) }
        }

        // Browser-internal pages (chrome://newtab, about:blank, …) used to get a fake domain.
        let withURL = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.url != nil }))) ?? []
        for segment in withURL where !ActivityContext.isWebURL(segment.url ?? "") {
            segment.url = nil
            segment.domain = nil
            segment.classificationKey = segment.context.classificationKey
            if segment.classificationSource != .manual {
                let (key, source) = classifier.classify(segment.context)
                segment.categoryKey = key
                segment.classificationSource = source
            }
        }
        // A rule added after the model answered (built-in or the user's) takes precedence.
        let ai = ClassificationSource.ai.rawValue
        let aiSegments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.classificationSourceRaw == ai }))) ?? []
        for segment in aiSegments {
            let (key, source) = classifier.classify(segment.context)
            guard source != .ai else { continue }
            segment.categoryKey = key
            segment.classificationSource = source
        }
        // Sessions stopped within a few minutes used to be recorded; they're mis-clicks.
        let sessions = (try? modelContext.fetch(FetchDescriptor<SessionRecord>())) ?? []
        for session in sessions where session.end.timeIntervalSince(session.start) < SessionEngine.minimumReviewDuration
            && session.end.timeIntervalSince(session.start) < session.plannedDuration - 1 {
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}
