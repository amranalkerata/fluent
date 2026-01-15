import SwiftUI
import SwiftData

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selection: $appState.selectedSidebarItem)
            } detail: {
                DetailView(selectedItem: appState.selectedSidebarItem)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 700, minHeight: 450)
            .onAppear {
                // Check if onboarding needed
                if !SettingsService.shared.isOnboardingComplete {
                    appState.showOnboarding = true
                }
            }

            // Onboarding overlay (non-dismissible)
            if appState.showOnboarding {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                OnboardingView()
                    .environmentObject(appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(FluentAnimation.normal, value: appState.showOnboarding)
    }
}

struct DetailView: View {
    let selectedItem: SidebarItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch selectedItem {
        case .home:
            HomeView()
        case .history:
            HistoryView()
        case .shortcuts:
            ShortcutsView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    MainWindow()
        .environmentObject(AppState())
        .modelContainer(for: [Recording.self], inMemory: true)
}
