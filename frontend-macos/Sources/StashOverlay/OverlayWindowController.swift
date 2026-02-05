import AppKit
import QuartzCore
import StashMacOSCore
import SwiftUI

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private static let collapsedPanelSize = NSSize(width: 96, height: 96)
    private static let trayPanelSize = NSSize(width: 360, height: 380)

    private let viewModel: OverlayViewModel
    private let panel: OverlayPanel
    private var projectPopover: NSPopover?
    private var workspaceWindowControllers: [String: ProjectWorkspaceWindowController] = [:]
    private var shouldPresentProjectPickerOnActivate = false
    private var didPromptForAccessibility = false
    private var attachedDocumentKeys: Set<String> = []
    private var trayConversationIDs: [String: String] = [:]

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let contentRect = NSRect(origin: .zero, size: Self.collapsedPanelSize)
        let panel = OverlayPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        let rootView = OverlayRootView(viewModel: viewModel)
        let hostingView = DraggableHostingView(rootView: rootView)
        hostingView.frame = contentRect
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        super.init(window: panel)
        panel.delegate = self
        hostingView.onActivationClick = { [weak self] in
            guard let self else { return }
            guard !self.viewModel.showsTrayInterface else { return }
            self.handleOverlayInteraction()
        }
        hostingView.shouldAllowTrackpadReposition = { [weak self] in
            guard let self else { return true }
            return !self.viewModel.showsTrayInterface
        }

        viewModel.stateDidChange = { [weak self] in
            self?.updateAppearance(animated: true)
        }
        viewModel.overlayTapped = { [weak self] in
            self?.handleOverlayInteraction()
        }
        viewModel.filesDropped = { [weak self] urls in
            self?.handleFilesDropped(urls)
        }
        viewModel.traySendRequested = { [weak self] message in
            self?.handleTraySendRequested(message)
        }
        viewModel.trayOpenFullAppRequested = { [weak self] in
            self?.handleTrayOpenFullAppRequested()
        }
        viewModel.trayProjectPickerRequested = { [weak self] in
            self?.presentProjectPickerPopover(openWorkspaceOnSelection: false)
        }

        positionInitial()
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewModel.isActive = true
        guard shouldPresentProjectPickerOnActivate else { return }
        shouldPresentProjectPickerOnActivate = false
        DispatchQueue.main.async { [weak self] in
            self?.presentProjectPickerPopover()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel.isActive = false
    }

    private func positionInitial() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let padding: CGFloat = 24
        let topOffset: CGFloat = 80
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - padding,
            y: screenFrame.maxY - size.height - topOffset
        )
        panel.setFrameOrigin(origin)
    }

    private func updateAppearance(animated: Bool) {
        let engaged = viewModel.isEngaged
        let targetAlpha: CGFloat = engaged ? 1.0 : 0.55
        let targetSize = viewModel.showsTrayInterface ? Self.trayPanelSize : Self.collapsedPanelSize

        updatePanelFrame(size: targetSize, animated: animated)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = targetAlpha
            }
        } else {
            panel.alphaValue = targetAlpha
        }
    }

    private func updatePanelFrame(size: NSSize, animated: Bool) {
        let current = panel.frame.size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else {
            return
        }

        let oldFrame = panel.frame
        let newOrigin = NSPoint(
            x: oldFrame.maxX - size.width,
            y: oldFrame.maxY - size.height
        )
        let newFrame = NSRect(origin: newOrigin, size: size)
        panel.setFrame(newFrame, display: true, animate: animated)
    }

    private func handleFilesDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            await self?.processDroppedFiles(urls)
        }
    }

    @MainActor
    private func processDroppedFiles(_ urls: [URL]) async {
        panel.makeKeyAndOrderFront(nil)
        shouldPresentProjectPickerOnActivate = false
        NSApp.activate(ignoringOtherApps: true)
        viewModel.isTrayVisible = true
        viewModel.isProcessingDrop = true
        viewModel.trayErrorText = nil
        defer { viewModel.isProcessingDrop = false }

        do {
            let project = try await viewModel.backendClient.ensureProjectSelection(
                preferredProjectID: viewModel.selectedProject?.id
            )
            viewModel.selectedProject = project
            projectPopover?.performClose(nil)

            let imported = importDroppedFiles(urls, into: project)
            guard !imported.urls.isEmpty else {
                viewModel.trayStatusText = nil
                viewModel.trayErrorText = imported.failures.isEmpty
                    ? "No files were imported."
                    : imported.failures.joined(separator: " | ")
                return
            }

            try await viewModel.backendClient.registerAssets(urls: imported.urls, projectID: project.id)
            let conversation = try await ensureTrayConversation(for: project)
            await refreshTrayMessages(projectID: project.id, conversationID: conversation.id)

            if !imported.failures.isEmpty {
                print("Asset drop partially imported: \(imported.failures.joined(separator: " | "))")
                viewModel.trayStatusText = nil
                viewModel.trayErrorText = imported.failures.joined(separator: " | ")
            } else {
                viewModel.trayStatusText = nil
                viewModel.trayErrorText = nil
            }
        } catch {
            print("Asset drop handling failed: \(error)")
            viewModel.trayStatusText = nil
            viewModel.trayErrorText = "Could not stash dropped items: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func handleOverlayInteraction() {
        if panel.isKeyWindow {
            presentProjectPickerPopover()
            return
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let detectedDocument = viewModel.detectedDocument {
            shouldPresentProjectPickerOnActivate = false
            Task { [weak self] in
                await self?.processDetectedDocumentInteraction(detectedDocument)
            }
            return
        }

        maybePromptForAccessibilityAccess()
        shouldPresentProjectPickerOnActivate = true
    }

    @MainActor
    private func presentProjectPickerPopover(openWorkspaceOnSelection: Bool = true) {
        if let projectPopover, projectPopover.isShown {
            return
        }

        guard let anchorView = panel.contentView else { return }

        let pickerViewModel = ProjectPickerViewModel(
            client: viewModel.backendClient,
            selectedProjectID: viewModel.selectedProject?.id
        )
        pickerViewModel.onPreferredPopoverSizeChange = { [weak self] size in
            self?.projectPopover?.contentSize = NSSize(width: size.width, height: size.height)
        }
        pickerViewModel.onProjectSelected = { [weak self] project in
            guard let self else { return }
            self.viewModel.selectedProject = project
            self.projectPopover?.performClose(nil)
            if openWorkspaceOnSelection {
                self.openWorkspaceWindow(for: project)
            } else {
                self.viewModel.isTrayVisible = true
                Task { [weak self] in
                    await self?.primeTrayConversation(for: project)
                }
            }
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let initialSize = pickerViewModel.preferredPopoverSize
        popover.contentSize = NSSize(width: initialSize.width, height: initialSize.height)
        popover.contentViewController = NSHostingController(rootView: ProjectPickerView(viewModel: pickerViewModel))
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        projectPopover = popover
    }

    @MainActor
    private func openWorkspaceWindow(for project: OverlayProject) {
        viewModel.selectedProject = project

        if let existing = workspaceWindowControllers[project.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ProjectWorkspaceWindowController(project: project)
        controller.onWindowClosed = { [weak self] projectID in
            self?.workspaceWindowControllers.removeValue(forKey: projectID)
        }
        workspaceWindowControllers[project.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleTraySendRequested(_ message: String) {
        Task { [weak self] in
            await self?.sendTrayMessage(message)
        }
    }

    private func handleTrayOpenFullAppRequested() {
        Task { [weak self] in
            await self?.openWorkspaceFromTray()
        }
    }

    @MainActor
    private func openWorkspaceFromTray() async {
        do {
            let project = try await viewModel.backendClient.ensureProjectSelection(
                preferredProjectID: viewModel.selectedProject?.id
            )
            viewModel.selectedProject = project
            viewModel.dismissTray()
            viewModel.isHovered = false
            viewModel.isActive = false
            openWorkspaceWindow(for: project)
        } catch {
            viewModel.trayStatusText = nil
            viewModel.trayErrorText = "Could not open full app: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func primeTrayConversation(for project: OverlayProject) async {
        do {
            let conversation = try await ensureTrayConversation(for: project)
            await refreshTrayMessages(projectID: project.id, conversationID: conversation.id)
            viewModel.trayErrorText = nil
            viewModel.trayStatusText = "Project set to \(project.name)."
        } catch {
            viewModel.trayStatusText = nil
            viewModel.trayErrorText = "Could not prepare tray chat: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func sendTrayMessage(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        viewModel.isTrayVisible = true
        viewModel.isTraySending = true
        viewModel.trayErrorText = nil
        viewModel.trayStatusText = "Sending..."
        defer { viewModel.isTraySending = false }

        do {
            let project = try await viewModel.backendClient.ensureProjectSelection(
                preferredProjectID: viewModel.selectedProject?.id
            )
            viewModel.selectedProject = project
            let conversation = try await ensureTrayConversation(for: project)
            let status = try await viewModel.backendClient.sendMessage(
                projectID: project.id,
                conversationID: conversation.id,
                content: trimmed
            )

            await refreshTrayMessages(projectID: project.id, conversationID: conversation.id)

            if let runID = status.runId {
                viewModel.trayStatusText = "Running..."
                let finalStatus = try await waitForRunCompletion(projectID: project.id, runID: runID, timeoutSeconds: 35)
                await refreshTrayMessages(projectID: project.id, conversationID: conversation.id)
                switch finalStatus.lowercased() {
                case "done":
                    viewModel.trayStatusText = "Reply ready."
                case "failed":
                    viewModel.trayStatusText = "Run failed."
                case "cancelled":
                    viewModel.trayStatusText = "Run cancelled."
                default:
                    viewModel.trayStatusText = "Run status: \(finalStatus)."
                }
            } else {
                viewModel.trayStatusText = "Message sent."
            }
        } catch {
            viewModel.trayStatusText = nil
            viewModel.trayErrorText = "Could not send message: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func ensureTrayConversation(for project: OverlayProject) async throws -> OverlayConversation {
        let conversations = try await viewModel.backendClient.listConversations(projectID: project.id)

        if let cachedID = trayConversationIDs[project.id],
           let cached = conversations.first(where: { $0.id == cachedID })
        {
            return cached
        }

        if let activeID = project.activeConversationId,
           let active = conversations.first(where: { $0.id == activeID })
        {
            trayConversationIDs[project.id] = active.id
            return active
        }

        if let latest = conversations.max(by: { conversationTimestamp($0) < conversationTimestamp($1) }) {
            trayConversationIDs[project.id] = latest.id
            return latest
        }

        let created = try await viewModel.backendClient.createConversation(projectID: project.id, title: "Quick Tray")
        trayConversationIDs[project.id] = created.id
        return created
    }

    private func conversationTimestamp(_ conversation: OverlayConversation) -> String {
        conversation.lastMessageAt ?? conversation.createdAt
    }

    @MainActor
    private func refreshTrayMessages(projectID: String, conversationID: String) async {
        do {
            let loaded = try await viewModel.backendClient.listMessages(projectID: projectID, conversationID: conversationID)
            viewModel.trayMessages = loaded.sorted(by: { $0.sequenceNo < $1.sequenceNo })
        } catch {
            viewModel.trayStatusText = nil
            viewModel.trayErrorText = "Could not load chat updates: \(error.localizedDescription)"
        }
    }

    private func waitForRunCompletion(projectID: String, runID: String, timeoutSeconds: Int) async throws -> String {
        let timeout = UInt64(timeoutSeconds) * 1_000_000_000
        var elapsed: UInt64 = 0
        var lastStatus = "running"

        while elapsed < timeout {
            let run = try await viewModel.backendClient.run(projectID: projectID, runID: runID)
            lastStatus = run.status
            let status = run.status.lowercased()
            if status == "done" || status == "failed" || status == "cancelled" {
                return run.status
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1_000_000_000
        }

        return lastStatus
    }

    @MainActor
    private func processDetectedDocumentInteraction(_ detectedDocument: DetectedDocumentContext) async {
        do {
            let project = try await viewModel.backendClient.ensureProjectSelection(
                preferredProjectID: viewModel.selectedProject?.id
            )
            projectPopover?.performClose(nil)
            openWorkspaceWindow(for: project)

            let attachmentKey = makeAttachmentKey(projectID: project.id, documentURL: detectedDocument.url)
            guard !attachedDocumentKeys.contains(attachmentKey) else { return }

            try await viewModel.backendClient.registerAssets(urls: [detectedDocument.url], projectID: project.id)
            attachedDocumentKeys.insert(attachmentKey)
        } catch {
            print("Detected document handling failed: \(error)")
        }
    }

    @MainActor
    private func maybePromptForAccessibilityAccess() {
        guard !viewModel.accessibilityTrusted else { return }
        guard !didPromptForAccessibility else { return }

        didPromptForAccessibility = true
        _ = viewModel.requestAccessibilityTrust(prompt: true)
    }

    private func makeAttachmentKey(projectID: String, documentURL: URL) -> String {
        "\(projectID)|\(documentURL.standardizedFileURL.path)"
    }
    private struct ImportedDropResult {
        var urls: [URL]
        var failures: [String]
    }

    private func importDroppedFiles(_ urls: [URL], into project: OverlayProject) -> ImportedDropResult {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ImportedDropResult(urls: [], failures: [error.localizedDescription])
        }

        var imported: [URL] = []
        var failures: [String] = []
        var uniqueByPath: [String: URL] = [:]
        for url in urls {
            uniqueByPath[url.standardizedFileURL.path] = url.standardizedFileURL
        }

        for source in uniqueByPath.values.sorted(by: { $0.path < $1.path }) {
            do {
                let destination = try transferDroppedItem(from: source, to: root, projectRoot: root)
                imported.append(destination)
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return ImportedDropResult(urls: imported, failures: failures)
    }

    private func transferDroppedItem(from sourceURL: URL, to destinationBase: URL, projectRoot: URL) throws -> URL {
        let fm = FileManager.default
        let source = sourceURL.standardizedFileURL
        let sourceAccess = source.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let desiredDestination = destinationBase.appendingPathComponent(source.lastPathComponent)
        let destination = uniqueDestinationURL(for: desiredDestination)
        guard isInsideProject(destination, root: projectRoot) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let sourceInsideProject = isInsideProject(source, root: projectRoot)
        if sourceInsideProject {
            if source.standardizedFileURL == destination.standardizedFileURL {
                return destination
            }
            if isDescendant(destination, of: source) {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFeatureUnsupportedError,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot move a folder into itself."]
                )
            }
            try fm.moveItem(at: source, to: destination)
            return destination
        }

        try fm.copyItem(at: source, to: destination)
        return destination
    }

    private func uniqueDestinationURL(for requested: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: requested.path) {
            return requested
        }

        let ext = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        let parent = requested.deletingLastPathComponent()

        for index in 1 ... 999 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem)-\(index)"
            } else {
                candidateName = "\(stem)-\(index).\(ext)"
            }
            let candidate = parent.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return parent.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private func isInsideProject(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var initialLocation: NSPoint = .zero
    var onActivationClick: (() -> Void)?
    var shouldAllowTrackpadReposition: (() -> Bool)?

    required init(rootView: Content) {
        onActivationClick = nil
        shouldAllowTrackpadReposition = nil
        super.init(rootView: rootView)
    }

    convenience init(rootView: Content, onActivationClick: (() -> Void)? = nil) {
        self.init(rootView: rootView)
        self.onActivationClick = onActivationClick
    }

    required init?(coder: NSCoder) {
        onActivationClick = nil
        shouldAllowTrackpadReposition = nil
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        let wasKeyWindow = window?.isKeyWindow ?? false
        initialLocation = event.locationInWindow
        window?.makeKeyAndOrderFront(nil)
        if !wasKeyWindow {
            onActivationClick?()
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        var newOrigin = window.frame.origin
        newOrigin.x += deltaX
        newOrigin.y += deltaY
        window.setFrameOrigin(newOrigin)
    }

    override func scrollWheel(with event: NSEvent) {
        if shouldAllowTrackpadReposition?() == false {
            super.scrollWheel(with: event)
            return
        }

        guard let window = window, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        // Treat a precise scroll gesture as a two-finger drag for repositioning the overlay.
        guard event.momentumPhase.isEmpty else { return }
        let deviceDirection: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let translationX = -event.scrollingDeltaX * deviceDirection
        let translationY = event.scrollingDeltaY * deviceDirection

        var newOrigin = window.frame.origin
        newOrigin.x += translationX
        newOrigin.y += translationY
        window.setFrameOrigin(newOrigin)

        keepCursorInsideOverlay(translationX: translationX, translationY: translationY)
    }

    private func keepCursorInsideOverlay(translationX: CGFloat, translationY: CGFloat) {
        guard var location = CGEvent(source: nil)?.location else { return }
        location.x += translationX
        // Quartz display coordinates use an inverted Y axis compared with AppKit.
        location.y -= translationY
        CGWarpMouseCursorPosition(location)
    }
}
