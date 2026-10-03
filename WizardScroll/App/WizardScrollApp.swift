import AppKit
import SwiftUI

@main
struct WizardScrollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            if appState.phase == .idle {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .accessibilityLabel("WizardScroll")
            } else {
                Image(systemName: appState.phase.menuBarSymbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("WizardScroll", id: "dashboard") {
            DashboardView()
                .environmentObject(appState)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Window("Edit System Prompt", id: "system-prompt") {
            SystemPromptEditorView()
        }
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudController: RecordingHUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        hudController = RecordingHUDController(appState: state)
        state.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
