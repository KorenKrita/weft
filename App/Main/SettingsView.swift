import OpenRizeKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var newExcludedApp = ""
    @State private var newExcludedDomain = ""
    @State private var exportMessage: String?

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed to read window titles.",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    Button("Open Settings") { SystemSettings.openAutomation() }
                } label: {
                    Text("Automation")
                    Text("Each browser asks once whether OpenRize may read the active tab's URL.")
                }
                LabeledContent {
                    switch model.classifier.aiAvailability {
                    case .available: Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable: Button("Open Settings") { SystemSettings.openAppleIntelligence() }
                    }
                } label: {
                    Text("Apple Intelligence")
                    switch model.classifier.aiAvailability {
                    case .available: Text("Unknown apps and sites are classified on device.")
                    case .unavailable(let reason): Text(reason)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Toggle("Pause tracking", isOn: $prefs.trackingPaused)
                Stepper("Daily work hours target: \(prefs.workHoursTarget.formatted()) h",
                        value: $prefs.workHoursTarget, in: 1...16, step: 0.5)
                Toggle("Notify when the target is reached and when overworking", isOn: $prefs.workHoursNotifications)
            }

            Section("Tracking") {
                Stepper("Count as away after \(prefs.idleThresholdMinutes) min without input",
                        value: $prefs.idleThresholdMinutes, in: 1...30)
                Toggle("Don't record window titles", isOn: $prefs.stripTitles)
                Toggle("Only record the domain of URLs", isOn: $prefs.urlHostOnly)
                ExclusionList(title: "Never track these apps (bundle IDs)", placeholder: "com.example.app",
                              items: $prefs.excludedBundleIDs, draft: $newExcludedApp)
                ExclusionList(title: "Never track these domains", placeholder: "bank.example.com",
                              items: $prefs.excludedDomains, draft: $newExcludedDomain)
            }

            Section("Sessions") {
                Stepper("Default focus session: \(prefs.defaultFocusMinutes) min", value: $prefs.defaultFocusMinutes, in: 5...240, step: 5)
                Stepper("Default meeting: \(prefs.defaultMeetingMinutes) min", value: $prefs.defaultMeetingMinutes, in: 5...240, step: 5)
                Stepper("Default break: \(prefs.defaultBreakMinutes) min", value: $prefs.defaultBreakMinutes, in: 1...60)
                Toggle("Full-screen break", isOn: $prefs.fullScreenBreak)
            }

            Section("Break reminders") {
                Toggle("Remind me to take breaks", isOn: $prefs.breakRemindersEnabled)
                Stepper("After \(prefs.breakReminderMinutes) min of continuous activity",
                        value: $prefs.breakReminderMinutes, in: 10...240, step: 5)
                    .disabled(!prefs.breakRemindersEnabled)
                Stepper("Snooze for \(prefs.snoozeMinutes) min", value: $prefs.snoozeMinutes, in: 1...60)
                    .disabled(!prefs.breakRemindersEnabled)
            }

            Section {
                Toggle("Block distractions during focus sessions", isOn: $prefs.blockerEnabled)
                Picker("Style", selection: $prefs.blockerStyle) {
                    Text("Full-screen overlay").tag(BlockerStyle.overlay)
                    Text("Notification").tag(BlockerStyle.notification)
                }
                .disabled(!prefs.blockerEnabled)
                Stepper("Trigger after \(prefs.refocusThresholdSeconds) s on a distracting app or site",
                        value: $prefs.refocusThresholdSeconds, in: 0...300, step: 5)
                    .disabled(!prefs.blockerEnabled)
                if !prefs.blockerAllowList.isEmpty {
                    LabeledContent("Allowed (\"not a distraction\")") {
                        Button("Reset") { prefs.blockerAllowList = [] }
                    }
                    ForEach(prefs.blockerAllowList, id: \.self) { key in
                        Text(key.split(separator: "|").last.map(String.init) ?? key).font(.callout.monospaced())
                    }
                }
            } header: {
                Text("Distraction blocker")
            } footer: {
                Text("Categories marked “Block” trigger the blocker. Change them under Categories.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent {
                    Button("Export CSV…", action: exportCSV)
                } label: {
                    Text("Export all activity")
                    Text("Everything is stored locally in ~/Library/Application Support/OpenRize.")
                }
                if let exportMessage {
                    Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { model.refreshPermissions() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "openrize-activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let iso = ISO8601DateFormatter()
        var csv = "start,end,duration_seconds,app,bundle_id,domain,title,url,category,classification\n"
        for segment in segments {
            let fields: [String] = [
                iso.string(from: segment.start), iso.string(from: segment.end), String(Int(segment.duration)),
                segment.appName, segment.bundleID, segment.domain ?? "", segment.title ?? "", segment.url ?? "",
                model.classifier.category(segment.categoryKey).name, segment.classificationSourceRaw,
            ]
            csv += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Exported \(segments.count) entries."
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant Access", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct ExclusionList: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.callout.monospaced())
                    Spacer()
                    Button {
                        items.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(placeholder, text: $draft, prompt: Text(placeholder))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}
