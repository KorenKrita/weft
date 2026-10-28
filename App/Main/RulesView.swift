import WeftKit
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var field: RuleField = .domain
    @State private var pattern = ""
    @State private var categoryKey = "code"

    var body: some View {
        Form {
            Section("Add a rule") {
                Picker("Match", selection: $field) {
                    ForEach(RuleField.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                }
                TextField("Pattern", text: $pattern, prompt: Text(Self.placeholder(for: field)))
                    .onSubmit(add)
                Picker("Category", selection: $categoryKey) {
                    ForEach(model.classifier.categories) { Text($0.name).tag($0.key) }
                }
                HStack {
                    Spacer()
                    Button("Add Rule", action: add)
                        .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if model.classifier.userRules.isEmpty {
                    Text("No rules yet. Rules are also created when you recategorize an app or site.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.classifier.userRules) { rule in
                    HStack {
                        Text(Self.label(for: rule.field)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(rule.pattern).font(.body.monospaced())
                        Spacer()
                        CategoryChip(category: model.classifier.category(rule.categoryKey))
                        Button {
                            model.classifier.deleteRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete rule and reclassify matching activity")
                    }
                }
            } header: {
                Text("Your rules")
            } footer: {
                Text("Your rules take priority over \(BuiltinRules.all.count) built-in rules. More specific matches (title, URL) win over domains, which win over apps. Anything no rule matches is classified by the model chosen in Settings, or guessed when there is none.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Rules")
    }

    private func add() {
        model.classifier.addRule(field: field, pattern: pattern, categoryKey: categoryKey)
        pattern = ""
    }

    static func label(for field: RuleField) -> String {
        switch field {
        case .bundleID: "App bundle ID"
        case .domain: "Domain"
        case .titleContains: "Title contains"
        case .urlContains: "URL contains"
        }
    }

    static func placeholder(for field: RuleField) -> String {
        switch field {
        case .bundleID: "com.apple.dt.Xcode"
        case .domain: "github.com"
        case .titleContains: "Pull Request"
        case .urlContains: "/watch?v="
        }
    }
}
