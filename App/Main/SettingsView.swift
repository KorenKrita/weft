import WeftKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The standard macOS settings window (⌘,), one tab per area.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Model", systemImage: "sparkles") { ModelSettings() }
            Tab("Tracking", systemImage: "record.circle") { TrackingSettings() }
            Tab("Sessions", systemImage: "timer") { SessionSettings() }
            Tab("Blocker", systemImage: "hand.raised") { BlockerSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Launch Weft at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Toggle("Pause tracking", isOn: $prefs.trackingPaused)
            }
            Section("Work hours") {
                Picker("Daily target", selection: $prefs.workHoursTarget) {
                    ForEach([4.0, 5, 6, 7, 7.5, 8, 8.5, 9, 10, 12], id: \.self) { hours in
                        Text(Format.duration(hours * 3600)).tag(hours)
                    }
                }
                Toggle("Notify when I reach the target and when I'm overworking", isOn: $prefs.workHoursNotifications)
                if prefs.workHoursNotifications { NotificationsOffNote() }
            }
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed to read window titles.",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    switch model.notificationPermission {
                    case .allowed?: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined?: Button("Allow", action: model.enableNotifications)
                    case .denied?: Button("Open Settings", action: model.enableNotifications)
                    case nil: EmptyView()
                    }
                } label: {
                    Text("Notifications")
                    Text("Needed for break reminders, work-hours alerts and session endings.")
                }
                LabeledContent {
                    Button("Open Settings") { SystemSettings.openAutomation() }
                } label: {
                    Text("Browsers")
                    Text("Each browser asks once whether Weft may read the active tab's URL.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown next to settings that rely on notifications macOS won't deliver.
private struct NotificationsOffNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let permission = model.notificationPermission, permission != .allowed {
            LabeledContent {
                Button(permission == .notDetermined ? "Allow" : "Open Settings", action: model.enableNotifications)
            } label: {
                Label("Notifications are off for Weft, so these can't reach you.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
            }
        }
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

// MARK: - Model

private struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var loaded = false
    /// The category the server gave Xcode, or why it couldn't answer.
    @State private var check: Result<String, any Error>?
    @State private var isChecking = false
    /// Bumped to check the server again.
    @State private var checks = 0

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Categorize with", selection: $prefs.modelProvider) {
                    Text("Apple Intelligence").tag(ModelProvider.appleIntelligence)
                    Text("OpenAI-compatible API").tag(ModelProvider.openAICompatible)
                }
                LabeledContent {
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case (.unavailable, .appleIntelligence):
                        Button("Open Settings") { SystemSettings.openAppleIntelligence() }
                    case (.unavailable, .openAICompatible):
                        Label("Not set up", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case (.available, .openAICompatible):
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else if case .success = check {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if case .failure = check {
                            Label("Can't connect", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                } label: {
                    Text("Status")
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Text("Runs on this Mac.")
                    case (.unavailable(let reason), _):
                        Text("\(reason) Until a model is available, Weft guesses from each app's App Store category and each site's name.")
                    case (.available, .openAICompatible):
                        switch check {
                        case _ where isChecking: Text("Checking \(host)…")
                        case .success(let category)?: Text("Requests go to \(host), which put Xcode in \(category).")
                        case .failure(let error)?: Text("\(error.localizedDescription) Until it answers, Weft guesses instead.")
                        case nil: Text("Requests go to \(host).")
                        }
                    }
                }
            } footer: {
                Text("The model categorizes apps and sites no rule knows, describes your work streams and writes daily reviews.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if prefs.modelProvider == .openAICompatible {
                Section {
                    TextField("Base URL", text: $baseURL, prompt: Text(RemoteModelConfig.defaultBaseURL))
                    TextField("Model", text: $modelName, prompt: Text("gpt-5-mini"))
                    SecureField("API key", text: $apiKey, prompt: Text("Not needed for local servers"))
                    HStack {
                        Spacer()
                        Button("Save", action: save).disabled(isChecking)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Works with OpenAI and any server with a compatible Chat Completions API, such as OpenRouter, DeepSeek, Ollama or LM Studio. Weft sends it the apps and sites it doesn't know with their window titles, the apps, sites and window titles behind each work stream, and your daily totals. The API key is kept in your keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadServer)
        .task(id: checks) { await checkServer() }
        .onChange(of: prefs.modelProvider) {
            model.applyModelChoice()
            loadServer()
            checks += 1
        }
    }

    private var host: String {
        RemoteModelConfig(baseURL: model.preferences.remoteBaseURL, model: "", apiKey: "").endpoint?.host() ?? "the server"
    }

    /// Fills in the saved server, reading the keychain only once a remote model is chosen.
    private func loadServer() {
        guard !loaded, model.preferences.modelProvider == .openAICompatible else { return }
        baseURL = model.preferences.remoteBaseURL
        modelName = model.preferences.remoteModel
        apiKey = Keychain.string(for: AppModel.apiKeyAccount) ?? ""
        loaded = true
    }

    /// Saves the server, switches to it and checks that it answers.
    private func save() {
        model.preferences.remoteBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.preferences.remoteModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: AppModel.apiKeyAccount)
        model.applyModelChoice()
        checks += 1
    }

    /// Asks the server about Xcode, so Status says whether it really answers rather than
    /// only whether it's filled in. Runs when the tab opens, the model changes or on Save.
    private func checkServer() async {
        check = nil
        isChecking = false
        guard model.preferences.modelProvider == .openAICompatible, model.classifier.aiAvailability == .available
        else { return }
        isChecking = true
        let outcome: Result<String, any Error>
        do {
            let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
            let result = try await model.ai.classify(xcode, categories: model.classifier.categories)
            outcome = .success(model.classifier.category(result.categoryKey).name)
        } catch {
            outcome = .failure(error)
        }
        // A newer check replaced this one.
        guard !Task.isCancelled else { return }
        check = outcome
        isChecking = false
    }
}

// MARK: - Tracking

private struct TrackingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newDomain = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Count as away after", selection: $prefs.idleThresholdMinutes) {
                    ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) min without input").tag($0) }
                }
            } footer: {
                Text("Meetings and video calls are never counted as away.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Don't record window titles", isOn: $prefs.stripTitles)
                Toggle("Only record the domain of URLs", isOn: $prefs.urlHostOnly)
            }
            Section {
                ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                    RemovableRow {
                        AppLabel(bundleID: bundleID)
                    } onRemove: {
                        prefs.excludedBundleIDs.removeAll { $0 == bundleID }
                    }
                }
                AppPicker(excluding: Set(prefs.excludedBundleIDs)) { bundleID in
                    prefs.excludedBundleIDs.append(bundleID)
                }
            } header: {
                Text("Never track these apps")
            }
            Section("Never track these websites") {
                ForEach(prefs.excludedDomains, id: \.self) { domain in
                    RemovableRow {
                        Label(domain, systemImage: "globe")
                    } onRemove: {
                        prefs.excludedDomains.removeAll { $0 == domain }
                    }
                }
                HStack {
                    TextField("Domain", text: $newDomain, prompt: Text("bank.example.com"))
                        .labelsHidden()
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        var value = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let domain = ActivityContext.domain(from: value.contains("://") ? value : "https://\(value)") { value = domain }
        guard !value.isEmpty, !model.preferences.excludedDomains.contains(value) else { return }
        model.preferences.excludedDomains.append(value)
        newDomain = ""
    }
}

/// Adds an app from the ones currently running, or any app chosen in an open panel.
private struct AppPicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
                .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            Section("Running apps") {
                ForEach(running, id: \.0) { bundleID, name in
                    Button {
                        onPick(bundleID)
                    } label: {
                        Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: bundleID)) }
                    }
                }
            }
            Divider()
            Button("Choose Another App…", action: chooseApp)
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !excluding.contains(bundleID) else { return }
        onPick(bundleID)
    }
}

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        Label {
            Text(Self.name(for: bundleID))
        } icon: {
            Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 18, height: 18)
        }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct RemovableRow<Content: View>: View {
    @ViewBuilder let content: Content
    let onRemove: () -> Void

    var body: some View {
        HStack {
            content
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

// MARK: - Sessions

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("Default durations") {
                durationPicker("Focus", $prefs.defaultFocusMinutes, options: [15, 20, 25, 30, 45, 50, 60, 90, 120])
                durationPicker("Meeting", $prefs.defaultMeetingMinutes, options: [15, 20, 25, 30, 45, 60, 90, 120])
                durationPicker("Break", $prefs.defaultBreakMinutes, options: [1, 3, 5, 10, 15, 20, 30])
                Toggle("Show breaks full screen", isOn: $prefs.fullScreenBreak)
            }
            Section {
                Toggle("Remind me to take breaks", isOn: $prefs.breakRemindersEnabled)
                durationPicker("After working for", $prefs.breakReminderMinutes, options: [20, 30, 45, 60, 75, 90, 120])
                    .disabled(!prefs.breakRemindersEnabled)
                durationPicker("Snooze for", $prefs.snoozeMinutes, options: [5, 10, 15, 20, 30])
                    .disabled(!prefs.breakRemindersEnabled)
                if prefs.breakRemindersEnabled { NotificationsOffNote() }
            } header: {
                Text("Break reminders")
            } footer: {
                Text("Only active time counts; being away from the Mac for 5 minutes or more resets the timer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func durationPicker(_ title: String, _ value: Binding<Int>, options: [Int]) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(Set(options + [value.wrappedValue])).sorted(), id: \.self) { minutes in
                Text(Format.minutesLabel(minutes)).tag(minutes)
            }
        }
    }
}

// MARK: - Blocker

private struct BlockerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Block distractions during focus sessions", isOn: $prefs.blockerEnabled)
                Picker("Style", selection: $prefs.blockerStyle) {
                    Text("Full-screen overlay").tag(BlockerStyle.overlay)
                    Text("Notification").tag(BlockerStyle.notification)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.blockerEnabled)
                Picker("Interrupt after", selection: $prefs.refocusThresholdSeconds) {
                    ForEach(Array(Set([0, 5, 10, 15, 30, 60, prefs.refocusThresholdSeconds])).sorted(), id: \.self) { seconds in
                        Text(seconds == 0 ? "Immediately" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!prefs.blockerEnabled)
            } footer: {
                Text("Categories marked as distracting trigger the blocker. Change them under Categories.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Never block") {
                if prefs.blockerAllowList.isEmpty {
                    Text("Apps and sites you mark as “not a distraction” appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.blockerAllowList, id: \.self) { key in
                    RemovableRow {
                        AllowListLabel(key: key)
                    } onRemove: {
                        prefs.blockerAllowList.removeAll { $0 == key }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Allow-list keys are classification keys: `bundleID` or `bundleID|domain`.
private struct AllowListLabel: View {
    let key: String

    var body: some View {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            Label(parts[1], systemImage: "globe")
        } else {
            AppLabel(bundleID: parts[0])
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var exportMessage: String?

    private var dataFolder: URL { WeftSchema.dataFolder }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Export CSV…", action: exportCSV)
                } label: {
                    Text("Export all activity")
                    Text("Every tracked entry with app, title, URL and category.")
                }
                if let exportMessage {
                    Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }
                } label: {
                    Text("Data folder")
                    Text("Everything stays on this Mac, in \(dataFolder.path(percentEncoded: false)).")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "weft-activity.csv"
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
