import Foundation

/// The caption a model produces for an entry.
struct DiarySummary: Codable, Hashable {
    var title: String
    var summary: String
}

/// Manages a local Ollama runtime and uses it to caption transcripts. If an
/// Ollama server is already running it attaches to it; otherwise it launches the
/// binary bundled inside the app. Two curated models (fast / best) can be
/// downloaded from inside the app, sharing the standard ~/.ollama model cache.
/// Fully local — no key, no cloud. iOS builds would swap this for a bundled MLX
/// model; the rest of the app doesn't care.
@MainActor
final class OllamaService: ObservableObject {
    struct LLMModel: Identifiable, Hashable {
        let tag: String        // the Ollama model name to pull/run
        let role: String       // "Fast" / "Best"
        let name: String       // display name
        let note: String
        var id: String { tag }
    }

    static let fast = LLMModel(tag: "llama3.2:3b", role: "Fast",
                               name: "Llama 3.2 · 3B", note: "Quick captions · ~2 GB")
    static let best = LLMModel(tag: "qwen2.5:7b-instruct", role: "Best",
                               name: "Qwen2.5 · 7B", note: "Richer captions · ~4.7 GB")
    static let catalog = [fast, best]

    /// Models for the "Ask your journal" chat — these need reliable tool-calling
    /// and reasoning. Standard shares weights with the Best caption model (so it's
    /// already present if that's downloaded); Deep is a heavier specialist worth
    /// downloading for accurate counting/aggregation over a large journal.
    static let assistantStandard = LLMModel(tag: "qwen2.5:7b-instruct", role: "Standard",
                                            name: "Qwen2.5 · 7B", note: "Capable, shared with Best captions · ~4.7 GB")
    static let assistantDeep = LLMModel(tag: "qwen2.5:14b-instruct", role: "Deep",
                                        name: "Qwen2.5 · 14B", note: "Strongest reasoning for the assistant · ~9 GB")
    static let assistantCatalog = [assistantStandard, assistantDeep]

    enum ServerState: Equatable {
        case stopped, starting, ready
        case failed(String)
    }

    struct PullState: Equatable {
        var fraction: Double = 0
        var status: String = "starting…"
        var done: Bool = false
        var error: String?
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var pulls: [String: PullState] = [:]
    @Published var activeTag: String {
        didSet { UserDefaults.standard.set(activeTag, forKey: "MurmurLLM") }
    }
    /// The model the "Ask your journal" chat uses (separate from the caption model).
    @Published var assistantTag: String {
        didSet { UserDefaults.standard.set(assistantTag, forKey: "MurmurAssistantLLM") }
    }

    private var process: Process?
    private var spawned = false

    private let host = "127.0.0.1"
    private let port = 11434
    private var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// Last-known set of downloaded model tags, persisted so onboarding can tell a
    /// genuinely-fresh machine (no models) from a normal launch where the Ollama
    /// server just hasn't answered yet. Refreshed to live truth once it does.
    private static let installedCacheKey = "MurmurInstalledLLMs"

    init() {
        activeTag = UserDefaults.standard.string(forKey: "MurmurLLM") ?? Self.best.tag
        assistantTag = UserDefaults.standard.string(forKey: "MurmurAssistantLLM") ?? Self.assistantDeep.tag
        if let cached = UserDefaults.standard.stringArray(forKey: Self.installedCacheKey) {
            installed = Set(cached)
        }
    }

    var activeModel: LLMModel { Self.catalog.first { $0.tag == activeTag } ?? Self.fast }
    func isInstalled(_ tag: String) -> Bool { installed.contains(tag) }

    // MARK: - Lifecycle

    /// Attaches to a running Ollama, or launches the bundled binary. Idempotent.
    func start() async {
        if serverState == .ready {
            return
        }
        serverState = .starting

        if await ping() {
            spawned = false
            await refreshInstalled()
            serverState = .ready
            return
        }

        guard let binary = resolveBinary() else {
            serverState = .failed("Ollama runtime not found in the app bundle.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "\(host):\(port)"
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            self.process = process
            spawned = true
        } catch {
            serverState = .failed("Couldn't start Ollama: \(error.localizedDescription)")
            return
        }

        // Wait for the server to answer (model load is separate).
        for _ in 0..<40 {
            if await ping() {
                await refreshInstalled()
                serverState = .ready
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        serverState = .failed("Ollama didn't come up in time.")
    }

    /// Terminates the server only if we launched it — never kills the user's own.
    func stop() {
        if spawned {
            process?.terminate()
        }
        process = nil
    }

    private func resolveBinary() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ollama").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for candidate in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Models

    private func ping() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func refreshInstalled() async {
        struct Tags: Decodable { let models: [Model]; struct Model: Decodable { let name: String } }
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            return
        }
        installed = Set(tags.models.map(\.name))
        UserDefaults.standard.set(Array(installed), forKey: Self.installedCacheKey)
    }

    /// Downloads a model, streaming progress into `pulls[tag]`.
    func pull(_ tag: String) async {
        pulls[tag] = PullState()

        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": tag, "stream": true])

        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONDecoder().decode(Line.self, from: data) else {
                    continue
                }
                if let error = obj.error {
                    pulls[tag]?.error = error
                    break
                }
                if let total = obj.total, let completed = obj.completed, total > 0 {
                    pulls[tag]?.fraction = Double(completed) / Double(total)
                }
                if let status = obj.status {
                    pulls[tag]?.status = status
                }
            }
            if pulls[tag]?.error == nil {
                pulls[tag]?.fraction = 1
                pulls[tag]?.done = true
            }
        } catch {
            pulls[tag]?.error = error.localizedDescription
        }

        await refreshInstalled()
    }

    /// Deletes a downloaded model via Ollama. Refuses to delete the active one.
    func delete(_ tag: String) async {
        guard tag != activeTag else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": tag])
        _ = try? await URLSession.shared.data(for: request)
        pulls[tag] = nil
        await refreshInstalled()
    }

    // MARK: - Captioning

    /// Default guidance per field. Custom prompts (from Settings) replace these.
    static let defaultTitleGuidance = "3–7 evocative words. No surrounding quotes, no trailing punctuation, no names or pronouns."
    // Pronoun-neutral by default (leads with the action). When a profile is set, the
    // persona clause is what tells the model to bring in the author's pronouns — so
    // with no profile, captions stay consistent instead of guessing a gender.
    static let defaultSummaryGuidance = "one or two past-tense sentences, like a diary caption. Lead with the action, e.g. \"Reflected on the week…\", \"Worked through a hard call…\"."

    /// The caption system prompt. `persona` (from `AppSettings.authorPersona`) tells
    /// the model who the entry is about and which pronouns to use; it's blank until
    /// the profile is set, so nothing empty is ever injected.
    private func systemPrompt(title: String?, summary: String?, persona: String) -> String {
        let persona = persona.isEmpty ? "" : persona + " "
        return """
        You caption entries in a personal spoken journal. \(persona)Given a raw \
        voice-note transcript, reply with ONLY a JSON object of the form \
        {"title": "...", "summary": "..."}.
        Title: \(title ?? Self.defaultTitleGuidance)
        Summary: \(summary ?? Self.defaultSummaryGuidance)
        Use only what's in the transcript; invent nothing.
        """
    }

    private func clip(_ text: String) -> String {
        text.count > 6000 ? String(text.prefix(6000)) + "…" : text
    }

    /// Low-level chat call returning the assistant's raw content string. The tidy
    /// pass rewrites far more text than a caption does, so it asks for a colder
    /// temperature and a longer ceiling.
    private func chat(system: String, user: String, json: Bool, temperature: Double = 0.4, timeout: TimeInterval = 120) async -> String? {
        var body: [String: Any] = [
            "model": activeTag,
            "stream": false,
            "options": ["temperature": temperature],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["format"] = "json" }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        struct ChatResponse: Decodable { let message: Message; struct Message: Decodable { let content: String } }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            return nil
        }
        return chat.message.content
    }

    /// A tool the model asked to run, with its arguments coerced to strings.
    struct ToolCall: Identifiable {
        let id = UUID()
        let name: String
        let arguments: [String: String]
    }

    /// One assistant turn from the chat endpoint: its text, any tool calls it
    /// requested, and the raw message dict to append verbatim before sending the
    /// tool results back (so the model keeps its own call context).
    struct ChatStep {
        let content: String
        let toolCalls: [ToolCall]
        let rawMessage: [String: Any]
    }

    /// One round-trip to the chat endpoint with tools available. The caller runs
    /// the tools and loops until `toolCalls` is empty. Returns nil if not ready.
    ///
    /// When `onToken` is supplied, the response is streamed and each content delta
    /// is delivered live (tool-call rounds emit no content, so tokens only flow on
    /// the final answer round). Without it, the call is a single blocking request.
    func chatStep(
        messages: [[String: Any]],
        tools: [[String: Any]],
        onToken: (@MainActor (String) -> Void)? = nil
    ) async -> ChatStep? {
        guard serverState == .ready, isInstalled(assistantTag) else { return nil }
        let streaming = onToken != nil
        var body: [String: Any] = [
            "model": assistantTag,
            "stream": streaming,
            "options": ["temperature": 0.2],
            "messages": messages,
        ]
        if !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if streaming {
            return await streamChat(request: request, onToken: onToken!)
        }

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            return nil
        }
        return Self.decodeStep(from: message)
    }

    /// Reads the chat endpoint's NDJSON stream, firing `onToken` per content delta
    /// and assembling the final ChatStep (content + any tool calls).
    private func streamChat(request: URLRequest, onToken: @MainActor (String) -> Void) async -> ChatStep? {
        guard let (bytes, _) = try? await URLSession.shared.bytes(for: request) else {
            return nil
        }
        var content = ""
        var rawToolCalls: [[String: Any]] = []
        do {
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = root["message"] as? [String: Any] else {
                    continue
                }
                if let delta = message["content"] as? String, !delta.isEmpty {
                    content += delta
                    onToken(delta)
                }
                // Ollama sends the full tool_calls array in one chunk, not deltas.
                if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    rawToolCalls = calls
                }
            }
        } catch {
            if content.isEmpty && rawToolCalls.isEmpty { return nil }
        }

        var message: [String: Any] = ["role": "assistant", "content": content]
        if !rawToolCalls.isEmpty { message["tool_calls"] = rawToolCalls }
        return Self.decodeStep(from: message)
    }

    /// Turns a raw assistant message dict into a ChatStep (parsing tool calls).
    private static func decodeStep(from message: [String: Any]) -> ChatStep {
        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var calls: [ToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for call in rawCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                var args: [String: String] = [:]
                if let rawArgs = fn["arguments"] as? [String: Any] {
                    for (key, value) in rawArgs { args[key] = "\(value)" }
                }
                calls.append(ToolCall(name: name, arguments: args))
            }
        }
        return ChatStep(content: content, toolCalls: calls, rawMessage: message)
    }

    /// Captions a transcript (both fields) with the active model. Never throws —
    /// falls back to a heuristic caption if the model isn't ready.
    func summarize(_ transcript: String, titlePrompt: String? = nil, summaryPrompt: String? = nil, persona: String = "") async -> DiarySummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DiarySummary(title: "Untitled", summary: "")
        }
        guard serverState == .ready, isInstalled(activeTag) else {
            return Self.fallback(for: trimmed)
        }

        let system = systemPrompt(title: titlePrompt, summary: summaryPrompt, persona: persona)
        guard let content = await chat(system: system, user: "Caption this transcript:\n\n\(clip(trimmed))", json: true),
              let contentData = content.data(using: .utf8),
              let summary = try? JSONDecoder().decode(DiarySummary.self, from: contentData) else {
            return Self.fallback(for: trimmed)
        }

        let title = summary.title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.\n"))
        return DiarySummary(
            title: title.isEmpty ? Self.fallback(for: trimmed).title : title,
            summary: summary.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Regenerates just the title. Returns nil if the model isn't ready.
    func regenerateTitle(from transcript: String, prompt: String? = nil, persona: String = "") async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, serverState == .ready, isInstalled(activeTag) else { return nil }
        let persona = persona.isEmpty ? "" : persona + " "
        let system = "You title entries in a personal spoken journal. \(persona)Reply with ONLY the title text — no quotes, no punctuation at the end. Title guidance: \(prompt ?? Self.defaultTitleGuidance) Use only what's in the transcript."
        guard let content = await chat(system: system, user: "Title this transcript:\n\n\(clip(trimmed))", json: false) else { return nil }
        return content.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.\n"))
    }

    /// Regenerates just the summary. Returns nil if the model isn't ready.
    func regenerateSummary(from transcript: String, prompt: String? = nil, persona: String = "") async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, serverState == .ready, isInstalled(activeTag) else { return nil }
        let persona = persona.isEmpty ? "" : persona + " "
        let system = "You summarize entries in a personal spoken journal. \(persona)Reply with ONLY the summary text. Summary guidance: \(prompt ?? Self.defaultSummaryGuidance) Use only what's in the transcript; invent nothing."
        guard let content = await chat(system: system, user: "Summarize this transcript:\n\n\(clip(trimmed))", json: false) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tidy-up

    /// Default guidance for the transcript rewrite — the layout half of the job.
    /// Custom prompts (from Settings) replace this section only; the fidelity rules
    /// around it always hold, so a custom prompt can't turn the copy-editor into an
    /// author.
    static let defaultTidyGuidance = """
    Break the text into paragraphs at natural shifts in topic.
    Fix punctuation, capitalisation and sentence boundaries.
    Cut filler and stammering — "um", "uh", "like", "you know", repeated false \
    starts — where removing it changes nothing else.
    """

    /// Rewrites a raw transcript into readable paragraphs. Returns nil if the model
    /// isn't ready or the rewrite came back empty. Long transcripts are rewritten in
    /// chunks and rejoined, so nothing is silently truncated.
    func tidy(_ transcript: String, prompt: String? = nil, persona: String = "") async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, serverState == .ready, isInstalled(activeTag) else {
            return nil
        }

        let persona = persona.isEmpty ? "" : persona + " "
        let system = """
        You are a transcript copy-editor for a personal spoken journal. \(persona)The \
        user message is one voice note as it came out of speech recognition. Rewrite \
        it so it reads well on the page.

        ## Rules
        Keep every fact, name, number, date and event, in the order they were said.
        Keep the speaker's own words, first-person voice and tone.
        Never summarize, condense or expand — your rewrite is about as long as the \
        transcript.
        Add nothing that isn't in the transcript: no introduction, no closing line, \
        no commentary.
        The transcript may start or end mid-thought. Leave it that way — don't add \
        words to round it off.

        ## Rewriting
        \(prompt ?? Self.defaultTidyGuidance)

        ## Mishearings
        Speech recognition gets words wrong. Correct a word only where the \
        surrounding sentence makes the intended one obvious — a name spelled \
        correctly elsewhere in the transcript, or a word that makes no sense in \
        context but has an obvious near-homophone that does. Where you can't tell \
        what was meant, keep the words exactly as they are.

        ## Output
        Reply with the rewritten transcript and nothing else — no preamble, no \
        heading, no quotes, no markdown.
        """

        var pieces: [String] = []
        for chunk in Self.chunk(trimmed) {
            guard let content = await chat(system: system, user: chunk, json: false, temperature: 0.2, timeout: 300) else {
                return nil
            }
            let cleaned = Self.stripPreamble(content)
            guard !cleaned.isEmpty else {
                return nil
            }
            pieces.append(cleaned)
        }

        let result = pieces.joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }

    /// Splits a transcript into model-sized pieces, cutting at the first sentence
    /// end past the limit so no sentence is halved. One piece for anything under the
    /// limit, which is the common case for a voice note. Characters are copied
    /// through verbatim — the join of the pieces is the original text.
    private static func chunk(_ text: String, limit: Int = 3500) -> [String] {
        guard text.count > limit else {
            return [text]
        }

        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= limit, ".!?".contains(character) {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            chunks.append(tail)
        }
        return chunks
    }

    /// Drops a leading "Here's the cleaned-up transcript:" line and any code fence
    /// the model wrapped its answer in, which smaller models do despite the prompt.
    private static func stripPreamble(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A preamble is a short opening line that ends in a colon and is followed by
        // the actual text — never a sentence of the journal itself.
        if let firstBreak = text.range(of: "\n") {
            let opener = text[text.startIndex..<firstBreak.lowerBound].trimmingCharacters(in: .whitespaces)
            if opener.count < 120, opener.hasSuffix(":") {
                text = String(text[firstBreak.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return text
    }

    /// A serviceable caption with no model: leading words as a title, first
    /// sentence as a summary.
    static func fallback(for text: String) -> DiarySummary {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        let title = words.isEmpty ? "Untitled" : words.prefix(1).uppercased() + words.dropFirst()
        let sentence = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        let summary = String(sentence.prefix(160)).trimmingCharacters(in: .whitespaces)
        return DiarySummary(title: title, summary: summary)
    }
}
