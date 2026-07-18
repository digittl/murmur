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
    static let defaultTitleGuidance = "a title of 3–7 words, evocative, with no surrounding quotes or trailing punctuation, and no personal pronouns"
    static let defaultSummaryGuidance = "a summary of one or two sentences in past tense, like a diary caption; use no personal pronouns (no I, we, you, he, she, they, or names) — lead with the action verb, e.g. \"Reflected on…\", \"Worked through…\""

    private func systemPrompt(title: String?, summary: String?) -> String {
        """
        You caption entries in a personal spoken journal. Given a raw voice-note \
        transcript, reply with ONLY a JSON object of the form \
        {"title": "...", "summary": "..."}. For the title, follow: \
        \(title ?? Self.defaultTitleGuidance). For the summary, follow: \
        \(summary ?? Self.defaultSummaryGuidance). Use only what's in the \
        transcript; invent nothing.
        """
    }

    private func clip(_ text: String) -> String {
        text.count > 6000 ? String(text.prefix(6000)) + "…" : text
    }

    /// Low-level chat call returning the assistant's raw content string.
    private func chat(system: String, user: String, json: Bool) async -> String? {
        var body: [String: Any] = [
            "model": activeTag,
            "stream": false,
            "options": ["temperature": 0.4],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["format"] = "json" }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
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
    func summarize(_ transcript: String, titlePrompt: String? = nil, summaryPrompt: String? = nil) async -> DiarySummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DiarySummary(title: "Untitled", summary: "")
        }
        guard serverState == .ready, isInstalled(activeTag) else {
            return Self.fallback(for: trimmed)
        }

        let system = systemPrompt(title: titlePrompt, summary: summaryPrompt)
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
    func regenerateTitle(from transcript: String, prompt: String? = nil) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, serverState == .ready, isInstalled(activeTag) else { return nil }
        let system = "You title entries in a personal spoken journal. Reply with ONLY the title text — no quotes, no punctuation at the end. Title guidance: \(prompt ?? Self.defaultTitleGuidance). Use only what's in the transcript."
        guard let content = await chat(system: system, user: "Title this transcript:\n\n\(clip(trimmed))", json: false) else { return nil }
        return content.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.\n"))
    }

    /// Regenerates just the summary. Returns nil if the model isn't ready.
    func regenerateSummary(from transcript: String, prompt: String? = nil) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, serverState == .ready, isInstalled(activeTag) else { return nil }
        let system = "You summarize entries in a personal spoken journal. Reply with ONLY the summary text. Summary guidance: \(prompt ?? Self.defaultSummaryGuidance). Use only what's in the transcript; invent nothing."
        guard let content = await chat(system: system, user: "Summarize this transcript:\n\n\(clip(trimmed))", json: false) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
