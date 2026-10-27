import OpenRizeKit
import SwiftData
import SwiftUI

/// Consecutive segments of the same app/site and category, shown as one row.
struct ActivityGroup: Identifiable {
    var segments: [ActivitySegment]

    var id: PersistentIdentifier { segments[0].persistentModelID }
    var first: ActivitySegment { segments[0] }
    var start: Date { first.start }
    var end: Date { segments[segments.count - 1].end }
    var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var titles: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.title).filter { seen.insert($0).inserted }
    }

    static func build(_ segments: [ActivitySegment], mergeGap: TimeInterval = 60) -> [ActivityGroup] {
        var groups: [ActivityGroup] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = groups.last,
               last.first.bundleID == segment.bundleID, last.first.domain == segment.domain,
               last.first.categoryKey == segment.categoryKey,
               segment.start.timeIntervalSince(last.end) <= mergeGap {
                last.segments.append(segment)
                groups[groups.count - 1] = last
            } else {
                groups.append(ActivityGroup(segments: [segment]))
            }
        }
        return groups
    }
}

struct ActivityList: View {
    let segments: [ActivitySegment]
    @State private var showAll = false

    var body: some View {
        let groups = ActivityGroup.build(segments).filter { $0.duration >= 10 }.reversed()
        let visible = showAll ? Array(groups) : Array(groups.prefix(40))
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { group in
                ActivityRow(group: group)
                Divider()
            }
            if groups.count > visible.count {
                Button("Show all \(groups.count) entries") { showAll = true }
                    .buttonStyle(.link)
                    .padding(.top, 8)
            }
        }
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let group: ActivityGroup

    var body: some View {
        let category = model.classifier.category(group.first.categoryKey)
        HStack(alignment: .top, spacing: 10) {
            Text("\(group.start.formatted(date: .omitted, time: .shortened))–\(group.end.formatted(date: .omitted, time: .shortened))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Image(nsImage: AppIcons.icon(for: group.first.bundleID))
                .resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.first.domain ?? group.first.appName).font(.callout.weight(.medium))
                if let title = group.titles.first {
                    Text(group.titles.count > 1 ? "\(title) (+\(group.titles.count - 1))" : title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(group.titles.prefix(10).joined(separator: "\n"))
                }
            }
            Spacer()
            Text(Format.duration(group.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            CategoryMenu(group: group, category: category)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

/// Lets the user fix a classification, either just here or as a rule for the app/site.
struct CategoryMenu: View {
    @Environment(AppModel.self) private var model
    let group: ActivityGroup
    let category: CategoryDefinition

    var body: some View {
        let target = group.first.domain ?? group.first.appName
        Menu {
            Menu("Always for \(target)") {
                categoryButtons { key in
                    if let domain = group.first.domain {
                        model.classifier.addRule(field: .domain, pattern: domain, categoryKey: key)
                    } else {
                        model.classifier.addRule(field: .bundleID, pattern: group.first.bundleID, categoryKey: key)
                    }
                }
            }
            Menu("Only this entry") {
                categoryButtons { key in
                    for segment in group.segments { model.classifier.setManualCategory(key, for: segment) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(category.color).frame(width: 8, height: 8)
                Text(category.name)
                if group.first.classificationSource == .pending {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).help("Waiting for on-device classification")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func categoryButtons(_ action: @escaping (String) -> Void) -> some View {
        ForEach(model.classifier.categories.filter { $0.key != CategoryDefinition.uncategorizedKey }) { category in
            Button(category.name) { action(category.key) }
        }
    }
}
