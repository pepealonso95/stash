import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class OverlayViewModel: ObservableObject {
    @Published var isHovered = false {
        didSet { stateDidChange?() }
    }
    @Published var isDragTarget = false {
        didSet { stateDidChange?() }
    }
    @Published var isActive = false {
        didSet { stateDidChange?() }
    }
    @Published var lastDroppedFiles: [URL] = []
    @Published var selectedProject: OverlayProject?
    @Published var detectedDocument: DetectedDocumentContext?
    @Published var accessibilityTrusted = false

    let backendClient = BackendClient()
    var stateDidChange: (() -> Void)?
    var overlayTapped: (() -> Void)?
    var filesDropped: (([URL]) -> Void)?
    private let documentDetector = DocumentContextDetector()

    var isEngaged: Bool {
        isHovered || isDragTarget || isActive
    }

    var overlayHelpText: String {
        if let detectedDocument {
            return "Detected \(detectedDocument.url.lastPathComponent) in \(detectedDocument.sourceAppName). Click to attach and chat."
        }
        if !accessibilityTrusted {
            return "Enable Accessibility permission to auto-detect open documents."
        }
        return "Drop files or click to choose a project."
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

    func handleDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        lastDroppedFiles = urls
        filesDropped?(urls)
    }
}

struct OverlayRootView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private var isAnimating: Bool {
        viewModel.isHovered || viewModel.isDragTarget || viewModel.isActive
    }

    var body: some View {
        ZStack {
            VisualEffectView(
                material: viewModel.isEngaged ? .popover : .hudWindow,
                blendingMode: .behindWindow,
                state: viewModel.isEngaged ? .active : .inactive
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 6) {
                StashIconView(isAnimating: isAnimating)
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
        .frame(width: 96, height: 96)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .help(viewModel.overlayHelpText)
        .onHover { hover in
            viewModel.isHovered = hover
        }
        .onTapGesture {
            viewModel.handleOverlayTap()
        }
        .onDrop(of: [UTType.fileURL], delegate: FileDropDelegate(viewModel: viewModel))
    }
}

struct StashIconView: View {
    let isAnimating: Bool

    var body: some View {
        StashIconAssetView()
            .scaleEffect(isAnimating ? 1.12 : 1.0)
            .shadow(color: Color.black.opacity(0.25), radius: isAnimating ? 8 : 4, x: 0, y: 2)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAnimating)
    }
}

struct StashIconAssetView: View {
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
                .frame(width: 80, height: 80)
        } else {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}
