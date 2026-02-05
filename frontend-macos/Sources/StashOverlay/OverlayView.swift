import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class OverlayViewModel: ObservableObject {
    @Published var isHovered = false {
        didSet {
            if oldValue != isHovered {
                stateDidChange?()
            }
        }
    }
    @Published var isDragTarget = false {
        didSet {
            if oldValue != isDragTarget {
                stateDidChange?()
            }
        }
    }
    @Published var isActive = false {
        didSet {
            if oldValue != isActive {
                stateDidChange?()
            }
        }
    }
    @Published var isTrayVisible = false {
        didSet {
            if oldValue != isTrayVisible {
                stateDidChange?()
            }
        }
    }
    @Published var isProcessingDrop = false {
        didSet {
            if oldValue != isProcessingDrop {
                stateDidChange?()
            }
        }
    }
    @Published var lastDroppedFiles: [URL] = []
    @Published var selectedProject: OverlayProject?
    @Published var detectedDocument: DetectedDocumentContext?
    @Published var accessibilityTrusted = false
    @Published var trayComposerText = ""
    @Published var trayMessages: [OverlayMessage] = []
    @Published var trayStatusText: String?
    @Published var trayErrorText: String?
    @Published var isTraySending = false
    @Published var isTrayAwaitingResponse = false

    let backendClient = BackendClient()
    var stateDidChange: (() -> Void)?
    var overlayTapped: (() -> Void)?
    var filesDropped: (([URL]) -> Void)?
    var traySendRequested: ((String) -> Void)?
    var trayOpenFullAppRequested: (() -> Void)?
    var trayProjectPickerRequested: (() -> Void)?
    private let documentDetector = DocumentContextDetector()
    private let maxTrackedDroppedFiles = 200

    var shouldPreviewTrayOnDrag: Bool {
        isDragTarget && !isActive
    }

    var showsTrayInterface: Bool {
        isTrayVisible || shouldPreviewTrayOnDrag || isProcessingDrop
    }

    var isEngaged: Bool {
        isHovered || isDragTarget || isActive || showsTrayInterface
    }

    var overlayHelpText: String {
        if showsTrayInterface {
            return "Drop files to stash them, ask a quick question, or open the full app."
        }
        if let detectedDocument {
            return "Detected \(detectedDocument.url.lastPathComponent) in \(detectedDocument.sourceAppName). Click to attach and chat."
        }
        if !accessibilityTrusted {
            return "Enable Accessibility permission to auto-detect open documents."
        }
        return "Drop files or click to choose a project."
    }

    var canSendTrayMessage: Bool {
        !isTraySending && !trayComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        accessibilityTrusted = documentDetector.requestAccessibilityTrust(prompt: false)

        documentDetector.onDetectedDocumentChange = { [weak self] detectedDocument in
            guard let self else { return }
            self.detectedDocument = detectedDocument
            self.stateDidChange?()
        }

        documentDetector.onAccessibilityTrustChange = { [weak self] trusted in
            guard let self else { return }
            self.accessibilityTrusted = trusted
            self.stateDidChange?()
        }

        documentDetector.start()
    }

    deinit {
        documentDetector.stop()
    }

    @discardableResult
    func requestAccessibilityTrust(prompt: Bool) -> Bool {
        documentDetector.requestAccessibilityTrust(prompt: prompt)
    }

    func handleOverlayTap() {
        overlayTapped?()
    }

    func handleDropEntered() {
        if !isDragTarget {
            isDragTarget = true
        }
        if !isActive, !isTrayVisible {
            isTrayVisible = true
        }
    }

    func handleDropExited() {
        if isDragTarget {
            isDragTarget = false
        }
        if lastDroppedFiles.isEmpty && !isProcessingDrop && !isActive && isTrayVisible {
            isTrayVisible = false
        }
    }

    func handleDroppedFiles(_ urls: [URL]) {
        let normalized = normalizedUniqueURLs(urls)
        guard !normalized.isEmpty else { return }

        var merged = lastDroppedFiles.map(\.standardizedFileURL)
        var seenPaths = Set(merged.map(\.path))
        for url in normalized where seenPaths.insert(url.path).inserted {
            merged.append(url)
        }
        if merged.count > maxTrackedDroppedFiles {
            merged.removeFirst(merged.count - maxTrackedDroppedFiles)
        }
        lastDroppedFiles = merged

        isTrayVisible = true
        trayErrorText = nil
        trayStatusText = "Preparing \(normalized.count) item(s)..."
        filesDropped?(normalized)
    }

    func submitTrayMessage() {
        let text = trayComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        trayComposerText = ""
        traySendRequested?(text)
    }

    func requestOpenFullApp() {
        trayOpenFullAppRequested?()
    }

    func requestProjectPicker() {
        trayProjectPickerRequested?()
    }

    func dismissTray() {
        isTrayVisible = false
        isDragTarget = false
        trayStatusText = nil
        trayErrorText = nil
    }

    private func normalizedUniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        var results: [URL] = []

        for url in urls {
            let normalized = url.standardizedFileURL
            let path = normalized.path
            guard !path.isEmpty else { continue }
            if seenPaths.insert(path).inserted {
                results.append(normalized)
            }
        }

        return results
    }
}

struct OverlayRootView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @FocusState private var isTrayComposerFocused: Bool

    private var isAnimating: Bool {
        viewModel.isHovered || viewModel.isDragTarget || viewModel.isActive || viewModel.showsTrayInterface
    }

    private var containerSize: CGSize {
        viewModel.showsTrayInterface ? CGSize(width: 360, height: 380) : CGSize(width: 96, height: 96)
    }

    private var cornerRadius: CGFloat {
        viewModel.showsTrayInterface ? 22 : 20
    }

    private var recentMessages: [OverlayMessage] {
        Array(viewModel.trayMessages.suffix(2))
    }

    private var visibleDroppedFiles: [URL] {
        Array(viewModel.lastDroppedFiles.suffix(2))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VisualEffectView(
                material: viewModel.showsTrayInterface || viewModel.isEngaged ? .popover : .hudWindow,
                blendingMode: .behindWindow,
                state: viewModel.isEngaged ? .active : .inactive
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            if viewModel.showsTrayInterface {
                trayInterface
            } else {
                compactInterface
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .help(viewModel.overlayHelpText)
        .onHover { hover in
            viewModel.isHovered = hover
        }
        .onTapGesture {
            guard !viewModel.showsTrayInterface else { return }
            viewModel.handleOverlayTap()
        }
        .onDrop(of: [UTType.fileURL], delegate: FileDropDelegate(viewModel: viewModel))
        .animation(.easeOut(duration: 0.18), value: viewModel.showsTrayInterface)
        .animation(.easeOut(duration: 0.12), value: viewModel.isDragTarget)
    }

    private var compactInterface: some View {
        ZStack {
            VStack(spacing: 6) {
                StashIconView(isAnimating: isAnimating, size: 80)
            }

            VStack {
                HStack {
                    Spacer()
                    if viewModel.detectedDocument != nil {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(Color.blue.opacity(0.95)))
                    }
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private var trayInterface: some View {
        VStack(spacing: 0) {
            trayHeader
                .padding(.top, 8)
                .padding(.bottom, 8)

            Divider()

            ScrollView(showsIndicators: false) {
                trayBody
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            trayFooter
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 12)
    }

    private var trayHeader: some View {
        HStack(spacing: 10) {
            StashIconView(isAnimating: isAnimating, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Quick Stash")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Drop files, chat quickly, keep context")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isProcessingDrop || viewModel.isTraySending {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewModel.requestOpenFullApp()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open full app")
            Button {
                viewModel.dismissTray()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var trayBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(viewModel.selectedProject?.name ?? "Selecting project...")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Spacer()
                Button("Projects") {
                    viewModel.requestProjectPicker()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Documents")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if visibleDroppedFiles.isEmpty {
                    Text(viewModel.isDragTarget ? "Release to attach files and folders." : "Drag documents or folders onto the overlay.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleDroppedFiles, id: \.path) { file in
                        HStack(spacing: 7) {
                            Image(systemName: file.hasDirectoryPath ? "folder.fill" : "doc.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(file.lastPathComponent)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .lineLimit(1)
                        }
                    }
                    if viewModel.lastDroppedFiles.count > visibleDroppedFiles.count {
                        Text("+\(viewModel.lastDroppedFiles.count - visibleDroppedFiles.count) more")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.12)))

            if !recentMessages.isEmpty || viewModel.isTrayAwaitingResponse {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    ForEach(recentMessages) { message in
                        let isUserMessage = message.role.lowercased() == "user"
                        HStack(spacing: 0) {
                            if isUserMessage {
                                Spacer(minLength: 28)
                            }

                            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 2) {
                                Text(isUserMessage ? "You" : "Stash")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text(message.content)
                                    .font(.system(size: 12, weight: .regular, design: .rounded))
                                    .lineLimit(2)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.1)))

                            if !isUserMessage {
                                Spacer(minLength: 28)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if viewModel.isTrayAwaitingResponse {
                        trayLoadingMessage
                    }
                }
            }
        }
    }

    private var trayLoadingMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Stash")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking...")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.1)))
    }

    private var trayFooter: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Ask a quick question...", text: $viewModel.trayComposerText, axis: .vertical)
                .lineLimit(1 ... 3)
                .textFieldStyle(.plain)
                .focused($isTrayComposerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isTrayComposerFocused ? Color.accentColor : Color.black.opacity(0.15), lineWidth: isTrayComposerFocused ? 2 : 1)
                )
                .onSubmit {
                    viewModel.submitTrayMessage()
                }
            Button {
                viewModel.submitTrayMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(viewModel.canSendTrayMessage ? Color.white : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(viewModel.canSendTrayMessage ? Color.accentColor : Color.black.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSendTrayMessage)
        }
    }
}

struct StashIconView: View {
    let isAnimating: Bool
    var size: CGFloat = 80

    var body: some View {
        StashIconAssetView(size: size)
            .scaleEffect(isAnimating ? 1.12 : 1.0)
            .shadow(color: Color.black.opacity(0.25), radius: isAnimating ? 8 : 4, x: 0, y: 2)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAnimating)
    }
}

struct StashIconAssetView: View {
    let size: CGFloat

    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "stashIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "archivebox.fill")
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}
