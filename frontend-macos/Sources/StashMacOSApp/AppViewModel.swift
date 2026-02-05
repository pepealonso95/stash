import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var backendURLText: String
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

    @Published var searchHits: [SearchHit] = []
    @Published var errorText: String?

    private var runPollTask: Task<Void, Never>?
    private var client: BackendClient

    init() {
        let defaultURL = ProcessInfo.processInfo.environment["STASH_BACKEND_URL"] ?? "http://127.0.0.1:8765"
        backendURLText = defaultURL
        client = BackendClient(baseURL: URL(string: defaultURL) ?? URL(string: "http://127.0.0.1:8765")!)
    }

    deinit {
        runPollTask?.cancel()
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

    func configureBackend() {
        guard let baseURL = URL(string: backendURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorText = "Invalid backend URL"
            return
        }
        client = BackendClient(baseURL: baseURL)
    }

    func bootstrap() async {
        await pingBackend()
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

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder for Stash"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await openProject(url: url) }
        }
    }

    func openProject(url: URL) async {
        configureBackend()
        do {
            let opened = try await client.createOrOpenProject(name: url.lastPathComponent, rootPath: url.path)
            project = opened
            projectRootURL = url
            refreshFiles()
            await refreshConversations()
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

    func refreshFiles() {
        guard let projectRootURL else {
            files = []
            return
        }
        files = FileScanner.scan(rootURL: projectRootURL)
    }

    func triggerIndex() async {
        guard let projectID = project?.id else {
            errorText = "Open a project first"
            return
        }

        do {
            try await client.triggerIndex(projectID: projectID)
            runStatusText = "Indexing started"
            errorText = nil
        } catch {
            errorText = "Could not trigger indexing: \(error.localizedDescription)"
        }
    }

    func searchContext(query: String) async {
        guard let projectID = project?.id else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }

        do {
            let response = try await client.search(projectID: projectID, query: trimmed, limit: 6)
            searchHits = response.hits
        } catch {
            errorText = "Search failed: \(error.localizedDescription)"
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
        runStatusText = "Run started"

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
