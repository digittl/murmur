import SwiftUI

/// The right-hand "Ask your journal" panel (a titlebar-toggled inspector). Sends
/// the user's question to the local Ollama model grounded in the diary
/// transcripts, so it can answer questions about anything that was recorded.
struct ChatView: View {
    @ObservedObject var store: ChatStore

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var ollama: OllamaService
    @EnvironmentObject private var settings: AppSettings

    @State private var input = ""
    @State private var isThinking = false
    @State private var streamingText: String?
    @State private var showHistory = false
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { store.messages }

    private let examples = [
        "What did I work on this week?",
        "When did I last mention sleep?",
        "Summarise my mood lately.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            conversation
            composer
        }
        .background(WindowTint.solid(settings.accent).ignoresSafeArea())
        .onAppear {
            // Auto-focus the composer when the drawer opens (a touch after the
            // move transition so the field is in the hierarchy to take focus).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { inputFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(settings.accent)
            Text("Ask your journal")
                .font(.headline)
            Spacer()

            let saved = store.conversations.filter { !$0.messages.isEmpty }
            if !saved.isEmpty {
                Button {
                    showHistory.toggle()
                } label: {
                    headerIcon("clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .help("Past chats")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    historyList(saved)
                }
            }

            Button {
                store.newConversation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
            } label: {
                headerIcon("square.and.pencil", nudgeY: -1)
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 44)
    }

    /// A uniformly-sized, center-aligned header glyph. Rendered `.resizable` into
    /// a fixed box so different SF Symbols (which have different intrinsic optical
    /// sizes and baselines) all draw at the same size and centre — the reason the
    /// clock and pencil looked misaligned before.
    private func headerIcon(_ name: String, nudgeY: CGFloat = 0) -> some View {
        Image(systemName: name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 15, height: 15)
            .offset(y: nudgeY)
            .frame(width: 26, height: 26)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
    }

    /// The past-chats popover: open or delete any conversation, or clear them all.
    private func historyList(_ saved: [ChatConversation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Past chats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(saved) { convo in
                        let isCurrent = convo.id == store.currentID
                        HStack(spacing: 8) {
                            Button {
                                store.select(convo.id)
                                showHistory = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "bubble.left")
                                        .font(.caption)
                                        .foregroundStyle(isCurrent ? AnyShapeStyle(settings.accent) : AnyShapeStyle(.secondary))
                                    Text(convo.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.delete(convo.id)
                            } label: {
                                Image(systemName: "trash").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Delete this chat")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isCurrent ? settings.accent.opacity(0.10) : Color.clear)
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            Divider()
            Button {
                store.deleteAll()
                showHistory = false
            } label: {
                Label("Delete all chats", systemImage: "trash")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
        .frame(maxHeight: 360)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                    if let streamingText {
                        bubble(ChatMessage(role: .assistant, text: streamingText)).id("streaming")
                    }
                    if isThinking {
                        thinkingBubble.id("thinking")
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) {
                if let last = messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: isThinking) {
                if isThinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
            .onChange(of: streamingText) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask anything about your recordings — the answer comes from your own transcripts, on-device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        input = example
                        send()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.caption)
                            Text(example)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(settings.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(settings.accent.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }

    /// Renders the model's markdown (bold, italics, code, links) while keeping its
    /// line breaks and bullet prefixes — SwiftUI's default markdown parse collapses
    /// whitespace, so we use the whitespace-preserving inline option.
    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            Text(rendered(message.text))
                .textSelection(.enabled)
                .foregroundStyle(message.role == .user ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(message.role == .user
                              ? AnyShapeStyle(settings.accent)
                              : AnyShapeStyle(.background.opacity(0.75)))
                )
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Reading your journal…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                TextField("Ask about your recordings…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.background.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(settings.accent.opacity(0.18))
                            )
                    )

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? settings.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)

            if !ready {
                Text("The assistant model isn't downloaded yet — open Settings ▸ Models ▸ Assistant to get it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private var ready: Bool {
        ollama.serverState == .ready && ollama.isInstalled(ollama.assistantTag)
    }

    private var canSend: Bool {
        ready && !isThinking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send (agentic tool loop)

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        input = ""

        var working = store.messages
        working.append(ChatMessage(role: .user, text: question))
        store.update(messages: working)

        // Retrieval pre-pass (Clod-style): search the journal on the question up
        // front and hand the model the evidence before its first call, so it
        // answers decisively instead of hedging or asking permission to look.
        let evidence = searchJournal(query: question, limit: 40)

        // Build the running message list: system + prior turns + this question,
        // then the pre-searched evidence as the freshest context to reason over.
        var convo: [[String: Any]] = [["role": "system", "content": Self.systemPrompt()]]
        for message in working {
            convo.append(["role": message.role.rawValue, "content": message.text])
        }
        convo.append(["role": "system", "content": """
        Entries already searched for the user's latest question (use these as your \
        primary evidence; search further only for terms these don't cover):

        \(evidence)
        """])
        isThinking = true
        streamingText = nil

        Task {
            var answer = "Sorry — I couldn't reach the model just now. Make sure the assistant model is downloaded in Settings ▸ Models."
            // Let the model search/look up entries with tools, over several rounds
            // so it can chase synonyms and gather everything before answering. The
            // final answer round streams its tokens into `streamingText` live.
            for _ in 0..<8 {
                let step = await ollama.chatStep(messages: convo, tools: Self.tools) { delta in
                    if isThinking { isThinking = false }
                    streamingText = (streamingText ?? "") + delta
                }
                guard let step else { break }
                if step.toolCalls.isEmpty {
                    if !step.content.isEmpty { answer = step.content }
                    break
                }
                // A tool round: any streamed text was just a preamble ("I'll search…")
                // — discard it so it doesn't concatenate with the real answer.
                streamingText = nil
                isThinking = true
                convo.append(step.rawMessage)
                for call in step.toolCalls {
                    let result = runTool(name: call.name, arguments: call.arguments)
                    convo.append(["role": "tool", "content": result, "tool_name": call.name])
                }
            }
            isThinking = false
            working.append(ChatMessage(role: .assistant, text: answer))
            store.update(messages: working)
            streamingText = nil
        }
    }

    private static func systemPrompt() -> String {
        let today = Date().formatted(date: .complete, time: .omitted)
        return """
        You are the user's personal journal assistant. Today is \(today).

        You CANNOT see the whole journal directly — it may be large. Relevant entries \
        for the current question are pre-searched and given to you in a system message; \
        base every statement ONLY on that evidence and on what the tools return. Never \
        answer from memory, and never guess or estimate.

        DECISIVENESS — this is critical:
        • Give ONE complete, self-contained answer per question. Do all your searching \
          first, silently, then answer.
        • NEVER end with a question or an offer to look further. Banned closers include \
          "Would you like me to check previous days?", "Would you like me to search \
          further?", "Let me know if you want more detail", and anything similar. If \
          more searching would help, just do it with the tools — never ask permission.
        • Your answer is final. Do not defer, hedge, or promise to look more later. If \
          the evidence is thin, say what you found and state plainly that there isn't \
          more — do not ask to keep looking.
        • NEVER restate or re-send an answer you have already given earlier in this \
          conversation. If the user says "yes"/"go on"/"continue", they want the NEXT \
          step or MORE detail, not a repeat — search deeper and add new information.
        • Do not narrate your process ("Let me search…", "I'll check…"). Just answer.

        How to work:
        • The pre-searched evidence is your starting point. If it doesn't fully cover \
          the question, call the tools with a high `limit` to gather the rest before \
          answering — don't stop at a partial view.
        • Try synonyms and related terms yourself. If a medication, place, or person \
          has other names or brand names (e.g. diazepam / Valium), search each and \
          combine the results — without asking.
        • For counting, totalling, or "how many / how much / how often" questions: \
          gather EVERY relevant entry, list the specific mentions with their dates, \
          and if entries state quantities (e.g. "took two tablets"), sum the actual \
          quantities — not the entry count. Show the per-entry breakdown, then the total.
        • Cite entries by date and title. If nothing relevant exists, or the data is \
          incomplete or ambiguous, say so plainly in your single answer instead of \
          inventing or deferring.

        Be accurate first, concise second. It is far better to say you're unsure than \
        to state a wrong number — but say it once, decisively.
        """
    }

    // MARK: - Tools

    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "search_journal",
            "description": "Full-text search across all diary transcripts, titles and summaries. Returns matching entries with date, title and the transcript.",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string", "description": "keywords or a phrase to search for"],
                "limit": ["type": "integer", "description": "maximum entries to return (default 25; use a high value for counting questions)"],
            ], "required": ["query"]],
        ]],
        ["type": "function", "function": [
            "name": "entries_on_date",
            "description": "Get every diary entry recorded on one calendar date, with full transcripts.",
            "parameters": ["type": "object", "properties": [
                "date": ["type": "string", "description": "the date in YYYY-MM-DD format"],
            ], "required": ["date"]],
        ]],
        ["type": "function", "function": [
            "name": "entries_in_range",
            "description": "List diary entries between two dates (inclusive) with date, title and summary.",
            "parameters": ["type": "object", "properties": [
                "start": ["type": "string", "description": "start date, YYYY-MM-DD"],
                "end": ["type": "string", "description": "end date, YYYY-MM-DD"],
            ], "required": ["start", "end"]],
        ]],
        ["type": "function", "function": [
            "name": "recent_entries",
            "description": "List the most recent diary entries with date, title and summary.",
            "parameters": ["type": "object", "properties": [
                "limit": ["type": "integer", "description": "how many recent entries (default 10)"],
            ], "required": []],
        ]],
    ]

    private func runTool(name: String, arguments: [String: String]) -> String {
        switch name {
        case "search_journal":
            return searchJournal(query: arguments["query"] ?? "", limit: int(arguments["limit"], default: 25))
        case "entries_on_date":
            return entriesOnDate(arguments["date"] ?? "")
        case "entries_in_range":
            return entriesInRange(start: arguments["start"] ?? "", end: arguments["end"] ?? "")
        case "recent_entries":
            return recentEntries(limit: int(arguments["limit"], default: 10))
        default:
            return "Unknown tool: \(name)"
        }
    }

    private func int(_ string: String?, default fallback: Int) -> Int {
        string.flatMap { Int($0) } ?? fallback
    }

    /// Common words that would match nearly every entry as a substring (notably
    /// the single letter "i"), diluting search relevance. Dropped before scoring.
    private static let stopwords: Set<String> = [
        "how", "many", "much", "often", "did", "does", "do", "the", "this", "that",
        "what", "when", "where", "why", "was", "were", "are", "and", "for", "with",
        "you", "your", "have", "has", "had", "about", "any", "all", "some", "from",
    ]

    private func searchJournal(query: String, limit: Int) -> String {
        let terms = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }
        guard !terms.isEmpty else { return "No query given." }
        let scored = library.entries.compactMap { entry -> (Entry, Int)? in
            let hay = "\(entry.title) \(entry.summary) \(entry.prose)".lowercased()
            let score = terms.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            return score > 0 ? (entry, score) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }

        guard !scored.isEmpty else {
            return "0 entries mention \"\(query)\". Try a different term or a synonym."
        }
        // Return every match (capped generously) with full transcripts and a count,
        // so counting/totalling questions have complete data to reason over.
        let cap = min(max(limit, 1), 40)
        let shown = scored.prefix(cap)
        var out = "\(scored.count) entr\(scored.count == 1 ? "y" : "ies") mention \"\(query)\""
        out += shown.count < scored.count ? " (showing the top \(shown.count) — raise limit to see more):\n\n" : ":\n\n"
        out += shown.map { entry, _ in block(entry, transcriptLimit: 1500) }.joined(separator: "\n\n")
        return out
    }

    private func entriesOnDate(_ dateString: String) -> String {
        guard let day = Self.parse(dateString) else { return "Couldn't read the date \"\(dateString)\"; use YYYY-MM-DD." }
        let matches = library.entries
            .filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
        guard !matches.isEmpty else { return "No entries recorded on \(dateString)." }
        return matches.map { block($0, transcriptLimit: 1500) }.joined(separator: "\n\n")
    }

    private func entriesInRange(start: String, end: String) -> String {
        guard let from = Self.parse(start), let to = Self.parse(end) else {
            return "Couldn't read the dates; use YYYY-MM-DD."
        }
        let lo = min(from, to), hi = Calendar.current.date(byAdding: .day, value: 1, to: max(from, to)) ?? max(from, to)
        let matches = library.entries
            .filter { $0.date >= lo && $0.date < hi }
            .sorted { $0.date > $1.date }
        guard !matches.isEmpty else { return "No entries between \(start) and \(end)." }
        return matches.prefix(30).map { entry in
            "[\(stamp(entry))] \(title(entry)) — \(entry.summary)"
        }.joined(separator: "\n")
    }

    private func recentEntries(limit: Int) -> String {
        let matches = library.entries.sorted { $0.date > $1.date }.prefix(max(1, limit))
        guard !matches.isEmpty else { return "The journal is empty." }
        return matches.map { entry in
            "[\(stamp(entry))] \(title(entry)) — \(entry.summary)"
        }.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private func block(_ entry: Entry, transcriptLimit: Int) -> String {
        let prose = entry.prose.count > transcriptLimit ? String(entry.prose.prefix(transcriptLimit)) + "…" : entry.prose
        return "[\(stamp(entry))] \(title(entry))\n\(prose)"
    }

    private func stamp(_ entry: Entry) -> String {
        entry.date.formatted(date: .abbreviated, time: .shortened)
    }

    private func title(_ entry: Entry) -> String {
        entry.title.isEmpty ? "Untitled" : entry.title
    }

    private static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: string.trimmingCharacters(in: .whitespaces))
    }
}

/// One turn in the journal chat.
struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    let text: String
}
