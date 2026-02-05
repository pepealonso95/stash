import AppKit
import ApplicationServices
import Foundation

struct DetectedDocumentContext: Equatable {
    let url: URL
    let sourceAppName: String
    let sourceBundleIdentifier: String?
    let windowTitle: String?
}

final class DocumentContextDetector {
    var onDetectedDocumentChange: ((DetectedDocumentContext?) -> Void)?
    var onAccessibilityTrustChange: ((Bool) -> Void)?

    private let workspace: NSWorkspace
    private var observerTokens: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var currentDocument: DetectedDocumentContext?
    private var accessibilityTrusted = AXIsProcessTrusted()

    private let supportedFileExtensions: Set<String> = [
        "pdf",
        "doc", "docx",
        "odt", "rtf", "txt", "md",
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp"
    ]

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    deinit {
        stop()
    }

    func start() {
        guard observerTokens.isEmpty else { return }

        let notificationCenter = workspace.notificationCenter
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        for token in observerTokens {
            workspace.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @discardableResult
    func requestAccessibilityTrust(prompt: Bool) -> Bool {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        updateAccessibilityTrust(trusted)
        if !trusted {
            setDetectedDocument(nil)
        }
        return trusted
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        updateAccessibilityTrust(trusted)
        guard trusted else {
            setDetectedDocument(nil)
            return
        }

        guard let app = workspace.frontmostApplication else {
            setDetectedDocument(nil)
            return
        }

        setDetectedDocument(resolveDocument(from: app))
    }

    private func resolveDocument(from app: NSRunningApplication) -> DetectedDocumentContext? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowElement = focusedWindowElement(for: appElement) else {
            return nil
        }

        let rawDocumentValue = attributeValue(kAXDocumentAttribute as CFString, element: windowElement)
        let windowTitle = attributeValue(kAXTitleAttribute as CFString, element: windowElement) as? String

        guard let documentURL = parseDocumentURL(rawDocumentValue), isSupportedDocument(documentURL) else {
            return nil
        }

        return DetectedDocumentContext(
            url: documentURL,
            sourceAppName: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
            sourceBundleIdentifier: app.bundleIdentifier,
            windowTitle: windowTitle
        )
    }

    private func focusedWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        if let focused = windowElementAttribute(kAXFocusedWindowAttribute as CFString, element: appElement) {
            return focused
        }
        if let main = windowElementAttribute(kAXMainWindowAttribute as CFString, element: appElement) {
            return main
        }
        return nil
    }

    private func attributeValue(_ attribute: CFString, element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    private func windowElementAttribute(_ attribute: CFString, element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attribute, element: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let windowElement: AXUIElement = value as! AXUIElement
        return windowElement
    }

    private func parseDocumentURL(_ rawValue: CFTypeRef?) -> URL? {
        if let url = rawValue as? URL, url.isFileURL {
            return url.standardizedFileURL
        }

        guard let stringValue = rawValue as? String else {
            return nil
        }

        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL
        {
            return url.standardizedFileURL
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        return nil
    }

    private func isSupportedDocument(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        let pathExtension = url.pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return false }
        return supportedFileExtensions.contains(pathExtension)
    }

    private func updateAccessibilityTrust(_ trusted: Bool) {
        guard accessibilityTrusted != trusted else { return }
        accessibilityTrusted = trusted
        onAccessibilityTrustChange?(trusted)
    }

    private func setDetectedDocument(_ document: DetectedDocumentContext?) {
        if currentDocument == document {
            return
        }
        currentDocument = document
        onDetectedDocumentChange?(document)
    }
}
