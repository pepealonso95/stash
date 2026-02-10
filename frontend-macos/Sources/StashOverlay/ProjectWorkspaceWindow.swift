import AppKit
import Foundation
import StashMacOSCore
import SwiftUI

final class ProjectWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private static let recommendedWorkspaceSize = NSSize(width: 1440, height: 860)
    private static let minimumWorkspaceSize = NSSize(width: 1220, height: 760)

    let projectID: String
    private let appViewModel: AppViewModel
    var onWindowClosed: ((String) -> Void)?
    var onWindowFocused: ((String) -> Void)?

    init(project: OverlayProject, backendURL: URL?) {
        projectID = project.id
        appViewModel = AppViewModel(
            initialProjectRootURL: URL(fileURLWithPath: project.rootPath, isDirectory: true),
            initialBackendURL: backendURL
        )

        let hostingController = NSHostingController(
            rootView: RootView(viewModel: appViewModel)
            .preferredColorScheme(.light)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.recommendedWorkspaceSize.width,
                height: Self.recommendedWorkspaceSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash - \(project.name)"
        window.minSize = Self.minimumWorkspaceSize
        window.contentViewController = hostingController
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    init(backendURL: URL?) {
        projectID = "__onboarding__"
        appViewModel = AppViewModel(initialBackendURL: backendURL)

        let hostingController = NSHostingController(
            rootView: RootView(viewModel: appViewModel)
            .preferredColorScheme(.light)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.recommendedWorkspaceSize.width,
                height: Self.recommendedWorkspaceSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash"
        window.minSize = Self.minimumWorkspaceSize
        window.contentViewController = hostingController
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?(projectID)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onWindowFocused?(projectID)
    }

    func ensureThreePaneWorkspaceFrame() {
        guard let window else { return }
        let minWidth = Self.minimumWorkspaceSize.width
        let minHeight = Self.minimumWorkspaceSize.height
        var nextFrame = window.frame

        if nextFrame.width < minWidth {
            nextFrame.origin.x -= (minWidth - nextFrame.width) / 2
            nextFrame.size.width = minWidth
        }
        if nextFrame.height < minHeight {
            nextFrame.origin.y -= (minHeight - nextFrame.height) / 2
            nextFrame.size.height = minHeight
        }
        if nextFrame != window.frame {
            window.setFrame(nextFrame, display: true, animate: true)
        }
    }

    func activateQuickChat(startNewConversation: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.appViewModel.startQuickChatSession(startNewConversation: startNewConversation)
        }
    }
}
