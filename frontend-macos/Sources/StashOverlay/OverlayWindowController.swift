import AppKit
import QuartzCore
import StashMacOSCore
import SwiftUI

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: OverlayViewModel
    private let panel: OverlayPanel
    private var projectPopover: NSPopover?
    private var shouldPresentProjectPickerOnActivate = false
    private var didPromptForAccessibility = false
    private var attachedDocumentKeys: [String: Date] = [:]
    private var workspaceWindowControllers: [String: ProjectWorkspaceWindowController] = [:]
    private var activeWorkspaceProjectID: String?
    private var onboardingWindowController: ProjectWorkspaceWindowController?

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let contentRect = NSRect(x: 0, y: 0, width: 96, height: 96)
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
            self?.handleOverlayInteraction()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.synchronizeSelectedProjectWithGlobalActive()
            self.presentProjectPickerPopover()
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
        await synchronizeSelectedProjectWithGlobalActive()

        guard await viewModel.backendClient.hasVisibleProjects() else {
            openOnboardingWorkspaceWindow()
            return
        }

        do {
            let project = try await viewModel.backendClient.resolveDropTargetProject(
                preferredProjectID: activeWorkspaceProjectID
            )
            projectPopover?.performClose(nil)
            openWorkspaceWindow(for: project)
            let imported = importDroppedFiles(urls, into: project)
            guard !imported.urls.isEmpty else {
                if !imported.failures.isEmpty {
                    print("Asset drop import failed: \(imported.failures.joined(separator: " | "))")
                }
                return
            }
            try await viewModel.backendClient.registerAssets(urls: imported.urls, projectID: project.id)
            if !imported.failures.isEmpty {
                print("Asset drop partially imported: \(imported.failures.joined(separator: " | "))")
            }
        } catch {
            print("Asset drop handling failed: \(error)")
        }
    }

    @MainActor
    private func handleOverlayInteraction() {
        if panel.isKeyWindow {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.synchronizeSelectedProjectWithGlobalActive()
                self.presentProjectPickerPopover()
            }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.synchronizeSelectedProjectWithGlobalActive()
            if await self.viewModel.backendClient.hasVisibleProjects() {
                self.shouldPresentProjectPickerOnActivate = true
            } else {
                self.openOnboardingWorkspaceWindow()
            }
        }
    }

    @MainActor
    private func presentProjectPickerPopover() {
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
            self.openWorkspaceWindow(for: project)
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
        onboardingWindowController?.window?.performClose(nil)
        onboardingWindowController = nil
        closeWorkspaceWindows(exceptProjectID: project.id)
        if let existing = workspaceWindowControllers[project.id] {
            existing.ensureThreePaneWorkspaceFrame()
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            activeWorkspaceProjectID = project.id
            Task { @MainActor [weak self] in
                await self?.syncActiveProjectSelection(projectID: project.id)
            }
            return
        }

        let controller = ProjectWorkspaceWindowController(
            project: project,
            backendURL: viewModel.backendClient.backendURL
        )
        controller.onWindowFocused = { [weak self] projectID in
            self?.activeWorkspaceProjectID = projectID
            Task { @MainActor [weak self] in
                await self?.syncActiveProjectSelection(projectID: projectID)
            }
        }
        controller.onWindowClosed = { [weak self] projectID in
            guard let self else { return }
            self.workspaceWindowControllers.removeValue(forKey: projectID)
            if self.activeWorkspaceProjectID == projectID {
                self.activeWorkspaceProjectID = nil
            }
        }
        workspaceWindowControllers[project.id] = controller
        activeWorkspaceProjectID = project.id
        Task { @MainActor [weak self] in
            await self?.syncActiveProjectSelection(projectID: project.id)
        }
        controller.ensureThreePaneWorkspaceFrame()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func openOnboardingWorkspaceWindow() {
        if let existing = onboardingWindowController {
            existing.ensureThreePaneWorkspaceFrame()
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ProjectWorkspaceWindowController(backendURL: viewModel.backendClient.backendURL)
        controller.onWindowClosed = { [weak self] _ in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.ensureThreePaneWorkspaceFrame()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func closeWorkspaceWindows(exceptProjectID keepProjectID: String) {
        for (projectID, controller) in workspaceWindowControllers where projectID != keepProjectID {
            controller.window?.performClose(nil)
        }
    }

    @MainActor
    private func processDetectedDocumentInteraction(_ detectedDocument: DetectedDocumentContext) async {
        do {
            let preferredID = activeWorkspaceProjectID ?? viewModel.selectedProject?.id
            let project = try await viewModel.backendClient.resolveDropTargetProject(preferredProjectID: preferredID)
            projectPopover?.performClose(nil)
            openWorkspaceWindow(for: project)

            let attachmentKey = makeAttachmentKey(projectID: project.id, documentURL: detectedDocument.url)
            guard canAttachDocument(withKey: attachmentKey) else { return }

            try await viewModel.backendClient.registerAssets(urls: [detectedDocument.url], projectID: project.id)
            markDocumentAttached(attachmentKey)
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
        let normalized = documentURL.standardizedFileURL
        let values = try? normalized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)
        return "\(projectID)|\(normalized.path)|\(size)|\(modified)"
    }

    private func canAttachDocument(withKey key: String) -> Bool {
        pruneAttachmentKeys()
        return attachedDocumentKeys[key] == nil
    }

    private func markDocumentAttached(_ key: String) {
        attachedDocumentKeys[key] = Date()
    }

    private func pruneAttachmentKeys() {
        let now = Date()
        let expirationInterval: TimeInterval = 6 * 60 * 60
        attachedDocumentKeys = attachedDocumentKeys.filter { now.timeIntervalSince($0.value) < expirationInterval }
        if attachedDocumentKeys.count <= 512 {
            return
        }
        let keep = attachedDocumentKeys
            .sorted { $0.value > $1.value }
            .prefix(384)
            .map { ($0.key, $0.value) }
        attachedDocumentKeys = Dictionary(uniqueKeysWithValues: keep)
    }

    @MainActor
    private func syncActiveProjectSelection(projectID: String) async {
        do {
            try await viewModel.backendClient.setActiveProject(projectID: projectID)
        } catch {
            print("Failed to sync active project \(projectID): \(error)")
            await synchronizeSelectedProjectWithGlobalActive()
        }
    }

    @MainActor
    private func synchronizeSelectedProjectWithGlobalActive() async {
        do {
            let synced = try await viewModel.backendClient.resolveDropTargetProject(
                preferredProjectID: activeWorkspaceProjectID
            )
            viewModel.selectedProject = synced
            activeWorkspaceProjectID = synced.id
        } catch {
            // Ignore sync errors here; selection resolution will retry on demand.
        }
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

        if source.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }

        if isDescendant(destination, of: source) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [NSLocalizedDescriptionKey: "Cannot copy a folder into itself."]
            )
        }

        // Deep copy semantics for dropped items: preserve source.
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

    required init(rootView: Content) {
        onActivationClick = nil
        super.init(rootView: rootView)
    }

    convenience init(rootView: Content, onActivationClick: (() -> Void)? = nil) {
        self.init(rootView: rootView)
        self.onActivationClick = onActivationClick
    }

    required init?(coder: NSCoder) {
        onActivationClick = nil
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
