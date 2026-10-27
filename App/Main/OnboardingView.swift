import OpenRizeKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Welcome to OpenRize").font(.title.bold())
                    Text("Automatic time tracking that stays on your Mac.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet("record.circle", "Records the frontmost app, window title and browser URL — no screenshots, no keystrokes.")
                bullet("sparkles", "Unknown apps and sites are categorized by Apple's on-device model. Nothing is uploaded.")
                bullet("scope", "Start Focus, Meeting or Break sessions from the menu bar.")
            }

            Form {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required to read window titles.",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    switch model.classifier.aiAvailability {
                    case .available: Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable: Button("Open Settings") { SystemSettings.openAppleIntelligence() }
                    }
                } label: {
                    Text("Apple Intelligence")
                    switch model.classifier.aiAvailability {
                    case .available: Text("Ready for on-device classification.")
                    case .unavailable(let reason): Text("\(reason) Built-in rules still work.")
                    }
                }
                LabeledContent("Browsers") {
                    Text("Each browser will ask once for permission.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 210)

            HStack {
                Spacer()
                Button("Get Started") {
                    model.preferences.hasCompletedOnboarding = true
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .task {
            // Pick up the Accessibility grant without requiring a relaunch.
            while !Task.isCancelled && !model.accessibilityGranted {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }
}
