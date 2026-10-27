import Foundation
import SwiftData

/// Idempotent upkeep of stored data, run at launch.
@MainActor
public enum Maintenance {
    public static func run(modelContext: ModelContext, classifier: ClassificationService) {
        // A rule that appeared after the model answered (e.g. a built-in rule shipped in a
        // newer version) takes precedence over the model's answer.
        let ai = ClassificationSource.ai.rawValue
        let aiSegments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.classificationSourceRaw == ai }))) ?? []
        for segment in aiSegments {
            let (key, source) = classifier.classify(segment.context)
            guard source != .ai else { continue }
            segment.categoryKey = key
            segment.classificationSource = source
        }
        try? modelContext.save()
    }
}
