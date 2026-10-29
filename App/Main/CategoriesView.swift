import WeftKit
import SwiftUI

/// The four category flags are mutually exclusive in practice, so they are presented as one
/// type per category.
enum CategoryType: CaseIterable, Identifiable {
    case focus, meeting, neutral, distracting, doNotTrack

    var id: Self { self }

    init(_ category: CategoryDefinition) {
        if category.isDoNotTrack { self = .doNotTrack }
        else if category.isMeeting { self = .meeting }
        else if category.blockInFocus { self = .distracting }
        else if category.isFocusTime { self = .focus }
        else { self = .neutral }
    }

    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .meeting: String(localized: "Meetings")
        case .neutral: String(localized: "Neutral")
        case .distracting: String(localized: "Distracting")
        case .doNotTrack: String(localized: "Don't Track")
        }
    }

    var symbol: String {
        switch self {
        case .focus: "scope"
        case .meeting: "person.2"
        case .neutral: "circle.dashed"
        case .distracting: "hand.raised"
        case .doNotTrack: "eye.slash"
        }
    }

    var explanation: String {
        switch self {
        case .focus: String(localized: "Counts as focus time and raises your Focus Score.")
        case .meeting: String(localized: "Counted separately; never marked as away while you listen.")
        case .neutral: String(localized: "Tracked, but neither focus nor distraction.")
        case .distracting: String(localized: "Lowers your Focus Score and triggers the blocker during focus sessions.")
        case .doNotTrack: String(localized: "Activity is discarded and never stored.")
        }
    }

    func apply(to category: inout CategoryDefinition) {
        category.isFocusTime = self == .focus
        category.isMeeting = self == .meeting
        category.blockInFocus = self == .distracting
        category.isDoNotTrack = self == .doNotTrack
    }
}

struct CategoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.classifier.categories.filter { $0.key != CategoryDefinition.uncategorizedKey }
        Form {
            ForEach(CategoryType.allCases) { type in
                let members = categories.filter { CategoryType($0) == type }
                Section {
                    if members.isEmpty {
                        Text("No categories").foregroundStyle(.tertiary)
                    }
                    ForEach(members) { category in
                        CategoryRow(category: category, type: type)
                    }
                } header: {
                    Label(type.title, systemImage: type.symbol)
                } footer: {
                    Text(type.explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Categories")
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CategoryDefinition
    let type: CategoryType
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(category.color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.displayName)
                if !category.hint.isEmpty {
                    Text(category.displayHint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Edit") { isEditing = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                    CategoryEditor(category: category) { model.classifier.updateCategory($0) }
                }
            Menu {
                ForEach(CategoryType.allCases.filter { $0 != type }) { target in
                    Button {
                        var updated = category
                        target.apply(to: &updated)
                        model.classifier.updateCategory(updated)
                    } label: {
                        Label(target.title, systemImage: target.symbol)
                    }
                }
            } label: {
                Text("Move to")
            }
            .fixedSize()
        }
    }
}

private struct CategoryEditor: View {
    @State private var draft: CategoryDefinition
    let onSave: (CategoryDefinition) -> Void
    @Environment(\.dismiss) private var dismiss

    init(category: CategoryDefinition, onSave: @escaping (CategoryDefinition) -> Void) {
        _draft = State(initialValue: category)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            ColorPicker("Color", selection: Binding(
                get: { draft.color },
                set: { draft.colorHex = $0.hexString }
            ), supportsOpacity: false)
            TextField("Description", text: $draft.hint, prompt: Text("What belongs here"), axis: .vertical)
                .lineLimit(2...4)
            Text("The description helps the model decide what goes into this category.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}
