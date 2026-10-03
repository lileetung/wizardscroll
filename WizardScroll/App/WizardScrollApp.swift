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
            MenuBarLabel(phase: appState.phase, appDelegate: appDelegate)
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

/// The menu bar label is the first view SwiftUI creates, so it hands the
/// `openWindow` action to the app delegate for AppKit-driven launches.
private struct MenuBarLabel: View {
    let phase: AppState.Phase
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if phase == .idle {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .accessibilityLabel("WizardScroll")
            } else {
                Image(systemName: phase.menuBarSymbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .onAppear {
            appDelegate.registerDashboardOpener { openWindow(id: "dashboard") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudController: RecordingHUDController?
    private var openDashboard: (() -> Void)?
    private var dashboardRequested = true

    func registerDashboardOpener(_ opener: @escaping () -> Void) {
        openDashboard = opener
        if dashboardRequested { showDashboard() }
    }

    private func showDashboard() {
        guard let openDashboard else {
            dashboardRequested = true
            return
        }
        dashboardRequested = false
        NSApp.activate(ignoringOtherApps: true)
        openDashboard()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        hudController = RecordingHUDController(appState: state)
        state.start()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopen(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
    }

    // SwiftUI swallows the reopen event without calling
    // `applicationShouldHandleReopen`, so take it over directly.
    @objc private func handleReopen(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        showDashboard()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
