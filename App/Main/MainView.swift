import OpenRizeKit
import SwiftUI

struct MainView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: Binding<Page?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) { page in
                Label(page.title, systemImage: page.symbol)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.page {
            case .today: DayView()
            case .reports: ReportsView()
            case .review: ReviewView()
            case .categories: CategoriesView()
            case .rules: RulesView()
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .environment(model)
        }
        .onAppear {
            // Show in the Dock and Cmd-Tab while the window is open.
            NSApp.setActivationPolicy(.regular)
            showOnboarding = !model.preferences.hasCompletedOnboarding
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
