import OpenRizeKit
import SwiftData
import SwiftUI

struct ActivityList: View {
    let segments: [ActivitySegment]
    @State private var showAll = false

    var body: some View {
        let groups = ActivityBlocks.build(segments).filter { $0.duration >= 10 }.reversed()
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
    let group: ActivityBlock

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
                let titles = group.titles
                if let title = titles.first {
                    Text(titles.count > 1 ? "\(title) (+\(titles.count - 1))" : title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(titles.prefix(10).joined(separator: "\n"))
                }
                if !group.interruptions.isEmpty {
                    let names = group.interruptionNames
                    Label("\(group.interruptions.count) brief switch\(group.interruptions.count == 1 ? "" : "es") · \(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? "…" : "")",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        .help("Short visits folded into this entry:\n" + names.joined(separator: "\n"))
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
    let group: ActivityBlock
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
