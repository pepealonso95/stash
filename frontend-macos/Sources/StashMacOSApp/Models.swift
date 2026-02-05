import Foundation

struct Project: Decodable, Identifiable {
    let id: String
    let name: String
    let rootPath: String
    let createdAt: String?
    let lastOpenedAt: String?
    let activeConversationId: String?
}

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let title: String
    let status: String
    let pinned: Bool
    let createdAt: String
    let lastMessageAt: String?
    let summary: String?
}

struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let conversationId: String
    let role: String
    let content: String
    let parentMessageId: String?
    let sequenceNo: Int
    let createdAt: String
}

struct RunDetail: Decodable {
    let id: String
    let projectId: String
    let conversationId: String
    let triggerMessageId: String
    let status: String
    let mode: String
    let outputSummary: String?
    let error: String?
}

struct TaskStatus: Decodable {
    let messageId: String
    let runId: String?
    let status: String
}

struct SearchResponse: Decodable {
    let query: String
    let hits: [SearchHit]
}

struct SearchHit: Decodable, Identifiable {
    let assetId: String
    let chunkId: String
    let score: Double
    let text: String
    let title: String?
    let pathOrUrl: String?

    var id: String { chunkId }
}

struct Health: Decodable {
    let ok: Bool
}

struct APIErrorResponse: Decodable {
    let detail: String
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let relativePath: String
    let name: String
    let depth: Int
    let isDirectory: Bool
}
