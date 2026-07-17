import Foundation

/// A saved "Ask your journal" conversation.
struct ChatConversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]

    /// A display title derived from the first user turn, trimmed to one line.
    static func makeTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.text else {
            return "New chat"
        }
        let line = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}

/// Persists journal-chat conversations to a JSON file in the library root, and
/// tracks which one is currently open. Kept above `ChatView` (in `ContentView`)
/// so history survives opening and closing the drawer and app relaunches.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []
    @Published var currentID: UUID?

    init() {
        load()
        currentID = conversations.first?.id
    }

    var current: ChatConversation? {
        conversations.first { $0.id == currentID }
    }

    var messages: [ChatMessage] {
        current?.messages ?? []
    }

    /// Starts a fresh, empty conversation and makes it current. The empty draft
    /// isn't written to disk until it has a message (see `update`).
    func newConversation() {
        let convo = ChatConversation(title: "New chat", updatedAt: .now, messages: [])
        conversations.insert(convo, at: 0)
        currentID = convo.id
    }

    func select(_ id: UUID) {
        currentID = id
    }

    /// Replaces the current conversation's messages, retitling from the first
    /// user turn, and persists. Creates a conversation first if none is current.
    func update(messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        if currentID == nil || current == nil {
            newConversation()
        }
        guard let idx = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        conversations[idx].messages = messages
        conversations[idx].title = ChatConversation.makeTitle(from: messages)
        conversations[idx].updatedAt = .now
        // Keep newest-first.
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id {
            currentID = conversations.first?.id
        }
        save()
    }

    func deleteAll() {
        conversations.removeAll()
        currentID = nil
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Storage.chatsFile),
              let saved = try? JSONDecoder().decode([ChatConversation].self, from: data) else {
            return
        }
        conversations = saved.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        // Never persist empty drafts.
        let toSave = conversations.filter { !$0.messages.isEmpty }
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        try? Storage.ensureDirectories()
        try? data.write(to: Storage.chatsFile, options: .atomic)
    }
}
