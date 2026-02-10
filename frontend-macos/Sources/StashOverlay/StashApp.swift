import AppKit
import SwiftUI

@main
struct StashOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: OverlayWindowController?
    private var hotkeyManager: GlobalHotkeyManager?
    private let settingsStore = OverlaySettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let viewModel = OverlayViewModel()
        windowController = OverlayWindowController(viewModel: viewModel)
        let hotkeyManager = GlobalHotkeyManager()
        hotkeyManager.onLatestQuickChat = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.windowController?.handleLatestQuickChatHotkey()
            }
        }
        hotkeyManager.onPickerQuickChat = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.windowController?.handlePickerQuickChatHotkey()
            }
        }
        hotkeyManager.start()
        self.hotkeyManager = hotkeyManager

        if settingsStore.overlayMode() == .visible {
            windowController?.showWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
        hotkeyManager = nil
    }
}
