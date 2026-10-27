import OpenRizeKit
import SwiftUI

struct CategoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.classifier.categories) { category in
                    CategoryRow(category: category) { model.classifier.updateCategory($0) }
                }
            } footer: {
                Text("**Focus** counts towards focus time and the Focus Score. **Meeting** time pauses idle detection. **Block** triggers the distraction blocker during focus sessions. **Don't track** discards matching activity entirely.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Categories")
    }
}

private struct CategoryRow: View {
    @State private var draft: CategoryDefinition
    let onChange: (CategoryDefinition) -> Void

    init(category: CategoryDefinition, onChange: @escaping (CategoryDefinition) -> Void) {
        _draft = State(initialValue: category)
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: Binding(
                get: { draft.color },
                set: { draft.colorHex = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft.name, prompt: Text("Name"))
                    .textFieldStyle(.plain).font(.body.weight(.medium))
                TextField("Hint", text: $draft.hint, prompt: Text("Hint for the classifier"))
                    .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()
            Spacer()
            Toggle("Focus", isOn: $draft.isFocusTime)
            Toggle("Meeting", isOn: $draft.isMeeting)
            Toggle("Block", isOn: $draft.blockInFocus)
            Toggle("Don't track", isOn: $draft.isDoNotTrack)
        }
        .toggleStyle(.checkbox)
        .onChange(of: draft) { _, new in onChange(new) }
    }
}
