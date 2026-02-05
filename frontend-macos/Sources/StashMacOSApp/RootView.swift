import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(CodexTheme.panel)

            Divider()

            HStack(spacing: 0) {
                WorkspaceSidebar(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 330)
                    .background(CodexTheme.panel)

                Divider()

                FilesPanel(viewModel: viewModel)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                    .background(CodexTheme.panel)

                Divider()

                ChatPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CodexTheme.canvas)
            }
        }
        .background(CodexTheme.canvas)
        .task {
            await viewModel.bootstrap()
        }
    }
}

private struct TopBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stash")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text("Codex-style workspace")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
            }

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Image(systemName: viewModel.backendConnected ? "bolt.horizontal.fill" : "bolt.slash")
                    .foregroundStyle(viewModel.backendConnected ? CodexTheme.success : CodexTheme.warning)
                TextField("Backend URL", text: $viewModel.backendURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button("Connect") {
                    viewModel.configureBackend()
                    Task { await viewModel.pingBackend() }
                }
                .buttonStyle(.borderedProminent)
            }

            Text(viewModel.backendStatusText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(viewModel.backendConnected ? CodexTheme.success : CodexTheme.warning)

            Button("Open Folder") {
                viewModel.chooseProjectFolder()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("Project")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)

                if let project = viewModel.project {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(project.rootPath)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .lineLimit(3)
                } else {
                    Text("No project selected")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button("New Chat") {
                    Task { await viewModel.createConversation() }
                }
                .buttonStyle(.borderedProminent)

                Button("Index") {
                    Task { await viewModel.triggerIndex() }
                }
                .buttonStyle(.bordered)
            }

            if let runStatusText = viewModel.runStatusText {
                Text(runStatusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary)
                    .padding(.vertical, 4)
            }

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.danger)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.08))
                    )
            }

            Divider()

            HStack {
                Text("Conversations")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                Button {
                    Task { await viewModel.refreshConversations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.conversations) { conversation in
                        Button {
                            Task { await viewModel.selectConversation(id: conversation.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(CodexTheme.textPrimary)
                                    .lineLimit(1)
                                Text(conversation.lastMessageAt ?? conversation.createdAt)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(CodexTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(viewModel.selectedConversationID == conversation.id ? CodexTheme.userBubble : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(CodexTheme.border.opacity(0.55), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(14)
    }
}

private struct FilesPanel: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                Button {
                    viewModel.refreshFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            TextField("Filter files", text: $viewModel.fileQuery)
                .textFieldStyle(.roundedBorder)

            List(viewModel.filteredFiles) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                        .foregroundStyle(item.isDirectory ? CodexTheme.accent : CodexTheme.textSecondary)
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                        .padding(.leading, CGFloat(item.depth) * 8)
                    Spacer()
                }
                .help(item.relativePath)
            }
            .listStyle(.inset)
        }
        .padding(14)
    }
}

private struct ChatPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedConversation?.title ?? "No Conversation")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(viewModel.project?.name ?? "Choose a project folder")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                }

                Spacer()

                TextField("Search indexed context", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                Button("Search") {
                    Task { await viewModel.searchContext(query: searchText) }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(CodexTheme.panel)

            Divider()

            if viewModel.messages.isEmpty {
                VStack(spacing: 14) {
                    Text("Start by asking Stash to work on project files")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text("Use plain language or send tagged commands between <codex_cmd> blocks.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageTimeline(messages: viewModel.messages)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !viewModel.searchHits.isEmpty {
                SearchHitStrip(hits: viewModel.searchHits)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            Divider()

            VStack(spacing: 10) {
                TextEditor(text: $viewModel.composerText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .frame(minHeight: 96, maxHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(CodexTheme.border, lineWidth: 1))

                HStack {
                    Text(viewModel.runInProgress ? "Run in progress..." : "Ready")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary)
                    Spacer()
                    Button("Run") {
                        Task { await viewModel.sendComposerMessage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSending || viewModel.project == nil)
                }
            }
            .padding(18)
            .background(CodexTheme.panel)
        }
    }
}

private struct MessageTimeline: View {
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    private var isUser: Bool {
        message.role.lowercased() == "user"
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.role.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(message.createdAt)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                }

                Text(message.content)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isUser ? CodexTheme.userBubble : CodexTheme.assistantBubble)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(CodexTheme.border.opacity(0.7), lineWidth: 1)
            )
            .frame(maxWidth: 780, alignment: .leading)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

private struct SearchHitStrip: View {
    let hits: [SearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context Hits")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hits) { hit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title ?? hit.pathOrUrl ?? "Indexed chunk")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(CodexTheme.textPrimary)
                                .lineLimit(1)
                            Text(hit.text)
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundStyle(CodexTheme.textSecondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .frame(width: 220, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(CodexTheme.border.opacity(0.7), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
}
