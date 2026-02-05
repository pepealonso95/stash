import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var backendConnected = false
    @Published var backendStatusText = "Backend offline"

    @Published var project: Project?
    @Published var projectRootURL: URL?
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: String?
    @Published var messages: [Message] = []

    @Published var files: [FileItem] = []
    @Published var fileQuery = ""

    @Published var composerText = ""
    @Published var isSending = false
    @Published var runStatusText: String?
    @Published var runInProgress = false
    @Published var indexingStatusText: String?

    @Published var errorText: String?

    private var runPollTask: Task<Void, Never>?
    private var filePollTask: Task<Void, Never>?
    private var indexStatusClearTask: Task<Void, Never>?
    private var lastFileSignature: Int?
    private var lastFileChangeIndexRequestAt = Date.distantPast
    private var didBootstrap = false
    private var isPresentingProjectPicker = false
    private let filePollInterval: Duration = .seconds(2)
    private let changeIndexCooldownSeconds: TimeInterval = 4
    private let defaults = UserDefaults.standard
    private let lastProjectPathKey = "stash.lastProjectPath"
    private var client: BackendClient

    init() {
        let defaultURL = ProcessInfo.processInfo.environment["STASH_BACKEND_URL"] ?? "http://127.0.0.1:8765"
        client = BackendClient(baseURL: URL(string: defaultURL) ?? URL(string: "http://127.0.0.1:8765")!)
    }

    deinit {
        runPollTask?.cancel()
        filePollTask?.cancel()
        indexStatusClearTask?.cancel()
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var filteredFiles: [FileItem] {
        let trimmed = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.relativePath.localizedCaseInsensitiveContains(trimmed) ||
                $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        await pingBackend()

        if let lastPath = defaults.string(forKey: lastProjectPathKey),
           FileManager.default.fileExists(atPath: lastPath)
        {
            await openProject(url: URL(fileURLWithPath: lastPath))
            return
        }
    }

    func pingBackend() async {
        do {
            _ = try await client.health()
            backendConnected = true
            backendStatusText = "Connected"
            errorText = nil
        } catch {
            backendConnected = false
            backendStatusText = "Offline"
            errorText = error.localizedDescription
        }
    }

    func presentProjectPicker() {
        guard !isPresentingProjectPicker else { return }
        isPresentingProjectPicker = true
        defer { isPresentingProjectPicker = false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder for Stash"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await openProject(url: url) }
        } else if project == nil {
            errorText = "No project selected. Pick a folder to start using Stash."
        }
    }

    func openProject(url: URL) async {
        do {
            let opened = try await client.createOrOpenProject(name: url.lastPathComponent, rootPath: url.path)
            project = opened
            projectRootURL = url
            defaults.set(url.path, forKey: lastProjectPathKey)

            await refreshFiles(force: true, triggerChangeIndex: false)
            startFilePolling()
            await refreshConversations()
            await autoIndexCurrentProject()
            await pingBackend()
            errorText = nil
        } catch {
            errorText = "Could not open project: \(error.localizedDescription)"
        }
    }

    func refreshConversations() async {
        guard let projectID = project?.id else { return }

        do {
            let loaded = try await client.listConversations(projectID: projectID)
            if loaded.isEmpty {
                let conversation = try await client.createConversation(projectID: projectID, title: "General")
                conversations = [conversation]
                selectedConversationID = conversation.id
                await loadMessages(conversationID: conversation.id)
                return
            }

            conversations = loaded
            if let selectedConversationID, loaded.contains(where: { $0.id == selectedConversationID }) {
                await loadMessages(conversationID: selectedConversationID)
            } else {
                let preferred = project?.activeConversationId
                selectedConversationID = loaded.first(where: { $0.id == preferred })?.id ?? loaded.first?.id
                if let selectedConversationID {
                    await loadMessages(conversationID: selectedConversationID)
                } else {
                    messages = []
                }
            }
        } catch {
            errorText = "Could not load conversations: \(error.localizedDescription)"
        }
    }

    func createConversation() async {
        guard let projectID = project?.id else {
            errorText = "Open a project before creating a conversation"
            return
        }

        let title = "Session \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
        do {
            let conv = try await client.createConversation(projectID: projectID, title: title)
            conversations.insert(conv, at: 0)
            selectedConversationID = conv.id
            messages = []
            errorText = nil
        } catch {
            errorText = "Could not create conversation: \(error.localizedDescription)"
        }
    }

    func selectConversation(id: String) async {
        selectedConversationID = id
        await loadMessages(conversationID: id)
    }

    func loadMessages(conversationID: String) async {
        guard let projectID = project?.id else { return }
        do {
            let loaded = try await client.listMessages(projectID: projectID, conversationID: conversationID)
            messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
            errorText = nil
        } catch {
            errorText = "Could not load messages: \(error.localizedDescription)"
        }
    }

    func refreshFiles() async {
        await refreshFiles(force: false, triggerChangeIndex: false)
    }

    private func refreshFiles(force: Bool, triggerChangeIndex: Bool) async {
        guard let projectRootURL else {
            files = []
            lastFileSignature = nil
            return
        }

        let scanned = await Task.detached(priority: .utility) {
            FileScanner.scan(rootURL: projectRootURL)
        }.value

        let signature = FileScanner.signature(for: scanned)
        let changed = force || signature != lastFileSignature
        let hadPreviousSnapshot = lastFileSignature != nil
        guard changed else { return }

        files = scanned
        lastFileSignature = signature

        guard triggerChangeIndex, hadPreviousSnapshot else { return }
        await autoIndexCurrentProject(fullScan: false, statusText: "New files detected. Re-indexing...")
    }

    func autoIndexCurrentProject(fullScan: Bool = true, statusText: String = "Auto-indexing project...") async {
        guard let projectID = project?.id else {
            return
        }

        if !fullScan {
            let now = Date()
            if now.timeIntervalSince(lastFileChangeIndexRequestAt) < changeIndexCooldownSeconds {
                return
            }
            lastFileChangeIndexRequestAt = now
        }

        indexingStatusText = statusText
        do {
            try await client.triggerIndex(projectID: projectID, fullScan: fullScan)
            indexingStatusText = fullScan ? "Indexing started" : "Change index started"
            scheduleIndexStatusClear()
        } catch {
            indexingStatusText = nil
            errorText = "Could not auto-index project: \(error.localizedDescription)"
        }
    }

    private func startFilePolling() {
        filePollTask?.cancel()
        filePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshFiles(force: false, triggerChangeIndex: true)
                try? await Task.sleep(for: self.filePollInterval)
            }
        }
    }

    private func scheduleIndexStatusClear() {
        indexStatusClearTask?.cancel()
        indexStatusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.indexingStatusText = nil
        }
    }

    func sendComposerMessage() async {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        guard let projectID = project?.id else {
            errorText = "Open a project first"
            return
        }

        isSending = true
        defer { isSending = false }

        if selectedConversationID == nil {
            await createConversation()
        }

        guard let conversationID = selectedConversationID else {
            errorText = "No active conversation"
            return
        }

        do {
            composerText = ""
            let status = try await client.sendMessage(
                projectID: projectID,
                conversationID: conversationID,
                content: content,
                startRun: true,
                mode: "manual"
            )

            await loadMessages(conversationID: conversationID)

            if let runID = status.runId {
                await pollRun(projectID: projectID, conversationID: conversationID, runID: runID)
            }
            await refreshConversations()
            errorText = nil
        } catch {
            errorText = "Could not send message: \(error.localizedDescription)"
        }
    }

    private func pollRun(projectID: String, conversationID: String, runID: String) async {
        runPollTask?.cancel()
        runInProgress = true
        runStatusText = "Running..."

        runPollTask = Task {
            defer {
                Task { @MainActor in
                    self.runInProgress = false
                }
            }

            for _ in 0 ..< 180 {
                if Task.isCancelled { return }

                do {
                    let run = try await self.client.run(projectID: projectID, runID: runID)
                    await MainActor.run {
                        self.runStatusText = "Run \(run.status)"
                    }

                    if ["done", "failed", "cancelled"].contains(run.status.lowercased()) {
                        await MainActor.run {
                            self.runStatusText = run.status.uppercased() + (run.error.map { ": \($0)" } ?? "")
                        }
                        await self.loadMessages(conversationID: conversationID)
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.errorText = "Run polling failed: \(error.localizedDescription)"
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(600))
            }

            await MainActor.run {
                self.runStatusText = "Run timed out"
            }
        }
    }
}
