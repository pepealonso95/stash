import AppKit
import Foundation
import StashMacOSCore
import SwiftUI

final class ProjectWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let projectID: String
    var onWindowClosed: ((String) -> Void)?
    var onWindowFocused: ((String) -> Void)?

    init(project: OverlayProject, backendURL: URL?) {
        projectID = project.id

        let hostingController = NSHostingController(
            rootView: RootView(
                initialProjectRootPath: project.rootPath,
                initialBackendURL: backendURL
            )
            .preferredColorScheme(.light)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash - \(project.name)"
        window.minSize = NSSize(width: 980, height: 700)
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

        let hostingController = NSHostingController(
            rootView: RootView(
                initialProjectRootPath: nil,
                initialBackendURL: backendURL
            )
            .preferredColorScheme(.light)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash"
        window.minSize = NSSize(width: 980, height: 700)
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
}
