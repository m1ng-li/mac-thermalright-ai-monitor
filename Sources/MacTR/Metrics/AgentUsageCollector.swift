// AgentUsageCollector.swift — Claude Code / Codex / Cursor usage collection
//
// Parses local session transcripts to report today's token usage and the
// agent's latest activity. No subprocess, no network:
//   Claude: ~/.claude/projects/<proj>/<session>.jsonl — per-message "usage"
//   Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — "token_count" events
//   Cursor: ~/.cursor/projects/<proj>/agent-transcripts/<id>/<id>.jsonl
//
// Files are read incrementally (per-file byte offsets) so the steady-state
// cost per tick is a stat() per candidate file plus any appended bytes —
// full parses happen only on first scan and day rollover.

import Darwin
import Foundation

// MARK: - Agent selection

/// Which agent fills a column in the AI Agents panel. Persisted so the left
/// and right slots can be freely remapped among Claude / Codex / Cursor.
enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case cursor = "cursor"

    var id: String { rawValue }

    /// Short label for Settings / menu UI.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Column header drawn on the LCD.
    var columnName: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        case .cursor: return "CURSOR"
        }
    }

    private static let leftKey = "agent.left"
    private static let rightKey = "agent.right"

    /// Left column — defaults to Cursor so it can be tried in Claude's old slot.
    static var left: AgentKind {
        get { AgentKind(rawValue: UserDefaults.standard.string(forKey: leftKey) ?? "") ?? .cursor }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: leftKey) }
    }

    /// Right column — defaults to Codex (unchanged).
    static var right: AgentKind {
        get { AgentKind(rawValue: UserDefaults.standard.string(forKey: rightKey) ?? "") ?? .codex }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: rightKey) }
    }
}

// MARK: - Data Structures

struct AgentUsage: Sendable {
    let available: Bool             // data directory exists at all
    let todayInputTokens: UInt64    // includes cache read/write tokens
    let todayOutputTokens: UInt64
    let secondsSinceActive: Int?    // nil = no session today
    let project: String?            // cwd basename of most recent session
    let activity: String?           // latest tool call / message summary
    let quotaUsedPercent: Double?   // rate-limit window usage (Codex only for now)
    let quotaResetsAt: Date?
    let needsAttention: Bool        // turn finished / waiting for user — flash the column
    let isWorking: Bool             // actively running a turn — slow breathing background
    let waitingFor: String?         // why it's blocked, e.g. "permission prompt"
    let model: String?              // model id of the active session
    let stepCurrent: Int?           // active plan step (1-based); nil = no plan
    let stepTotal: Int?             // total plan steps
    let stepText: String?           // description of the active step
    let hasTokenUsage: Bool         // false when the source never writes tokens (Cursor)
    var todayTotalTokens: UInt64 { todayInputTokens + todayOutputTokens }

    init(available: Bool, todayInputTokens: UInt64, todayOutputTokens: UInt64,
         secondsSinceActive: Int?, project: String?, activity: String?,
         quotaUsedPercent: Double? = nil, quotaResetsAt: Date? = nil,
         needsAttention: Bool = false, isWorking: Bool = false,
         waitingFor: String? = nil, model: String? = nil,
         stepCurrent: Int? = nil, stepTotal: Int? = nil, stepText: String? = nil,
         hasTokenUsage: Bool = true) {
        self.available = available
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.secondsSinceActive = secondsSinceActive
        self.project = project
        self.activity = activity
        self.quotaUsedPercent = quotaUsedPercent
        self.quotaResetsAt = quotaResetsAt
        self.needsAttention = needsAttention
        self.isWorking = isWorking
        self.waitingFor = waitingFor
        self.model = model
        self.stepCurrent = stepCurrent
        self.stepTotal = stepTotal
        self.stepText = stepText
        self.hasTokenUsage = hasTokenUsage
    }
}

struct AgentsSnapshot: Sendable {
    let claude: AgentUsage
    let codex: AgentUsage
    let cursor: AgentUsage

    func usage(for kind: AgentKind) -> AgentUsage {
        switch kind {
        case .claude: return claude
        case .codex:  return codex
        case .cursor: return cursor
        }
    }
}

// MARK: - Collector

final class AgentUsageCollector: @unchecked Sendable {

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Incremental state, reset on day rollover
    private var dayKey = ""
    private var todayStartISO = ""      // lexical threshold for ISO8601 "Z" timestamps
    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeSeenIDs: Set<String> = []
    private var claudeInput: UInt64 = 0
    private var claudeOutput: UInt64 = 0
    private var codexOffsets: [String: UInt64] = [:]
    private var codexInput: UInt64 = 0
    private var codexOutput: UInt64 = 0
    // Cursor's agent-transcripts don't carry per-message token usage (those
    // fields are zeroed in the IDE DB too), so we don't accumulate offsets —
    // only activity/plan/model from the freshest transcript.

    // Attention edge tracking — flash only for the first N seconds after the
    // waiting/done state appears, not for as long as it persists
    private let flashDuration: TimeInterval = 10
    private var claudePrevAttention = false
    private var claudeAttentionSince: Date?
    private var codexPrevAttention = false
    private var codexAttentionSince: Date?
    private var cursorPrevAttention = false
    private var cursorAttentionSince: Date?

    // Live Codex subscription quota from ChatGPT's wham/usage API (same source as
    // the Codex client / `tokens codex status`). Session transcripts only carry
    // a stale snapshot that can sit at 100% while the real weekly window is fine.
    private var codexQuotaCache: (used: Double, resets: Date?)?
    private var codexQuotaLastFetch: Date?
    private var codexQuotaInFlight = false
    private let codexQuotaLock = NSLock()

    func collect() -> AgentsSnapshot {
        rolloverIfNeeded()
        return AgentsSnapshot(claude: collectClaude(),
                              codex: collectCodex(),
                              cursor: collectCursor())
    }

    /// Reset accumulators at local midnight. Timestamps in both formats are
    /// UTC ISO8601 ("...Z"), so "today" = lexical compare against the local
    /// midnight rendered in UTC.
    private func rolloverIfNeeded() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let key = df.string(from: Date())
        guard key != dayKey else { return }
        dayKey = key

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        todayStartISO = iso.string(from: Calendar.current.startOfDay(for: Date()))

        claudeOffsets = [:]; claudeSeenIDs = []; claudeInput = 0; claudeOutput = 0
        codexOffsets = [:]; codexInput = 0; codexOutput = 0
    }

    // MARK: - Claude

    private func collectClaude() -> AgentUsage {
        let root = home + "/.claude/projects"
        guard fm.fileExists(atPath: root) else {
            return AgentUsage(available: false, todayInputTokens: 0, todayOutputTokens: 0,
                              secondsSinceActive: nil, project: nil, activity: nil)
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        var latestPath: String?
        var latestMtime = Date.distantPast
        let liveStates = claudeSessionStates()
        // Transcript of the freshest session that is blocked on the user
        var blockedPath: String?
        var blockedMtime = Date.distantPast

        for projDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dirPath = root + "/" + projDir
            for file in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = dirPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }
                // Latest session overall (any day) — drives the activity/project
                // display so the column isn't blank on a day with no runs yet
                if mtime > latestMtime { latestMtime = mtime; latestPath = path }

                // With several sessions running, the most-recently-written one is
                // whichever is busiest — which would mask a different session sitting
                // on a permission prompt. Being blocked on you outranks being busy.
                if mtime > blockedMtime,
                   liveStates[(file as NSString).deletingPathExtension]?.isBlocked == true {
                    blockedMtime = mtime; blockedPath = path
                }

                // Token counting is scoped to today only
                guard mtime >= todayStart else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                consumeNewLines(path: path, size: size, offsets: &claudeOffsets,
                                prefilter: "\"type\":\"assistant\"") { line in
                    self.accumulateClaudeLine(line)
                }
            }
        }

        var project: String?
        var activity: String?
        var secondsAgo: Int?
        var attention = false
        var working = false
        var waitingFor: String?
        var model: String?
        var step: (current: Int, total: Int, text: String)?
        if let blockedPath { latestPath = blockedPath; latestMtime = blockedMtime }
        if let path = latestPath {
            let ago = max(0, Int(Date().timeIntervalSince(latestMtime)))
            secondsAgo = ago
            let rawWaiting: Bool
            (project, activity, rawWaiting, step, model) = claudeActivity(path: path)

            // A permission prompt and a running tool look IDENTICAL in the transcript
            // — both end on an assistant tool_use with no tool_result yet — so the
            // tail heuristic below reads "needs confirmation" as "still working" and
            // never flashes. Claude Code publishes the real UI state per session;
            // prefer it and fall back to the transcript only when it's absent.
            let sessionID = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            let live = liveStates[sessionID]
            // Blocked on the user is actionable, not merely informational, so it
            // keeps flashing until answered instead of using the 10s done-window.
            var persistentAttention = false

            if live?.isBlocked == true {
                working = false
                attention = true
                persistentAttention = true
                waitingFor = live?.waitingFor
            } else {
                switch live?.status {
                case "waiting":
                    // Blocked, but you've left it sitting — show the state, stop nagging
                    working = false
                    attention = false
                    waitingFor = live?.waitingFor
                case "busy", "shell":
                    working = true
                    attention = false
                case "idle":
                    // Turn ended, Claude awaits your next prompt → the done-flash
                    working = false
                    attention = ago < 900
                default:
                    // No live session record (CLI exited, or an older build) — infer
                    // from the transcript tail as before.
                    working = !rawWaiting && ago < 90
                    // Only flash for recent events — stale sessions shouldn't blink all day
                    attention = rawWaiting && ago < 900
                }
            }

            // Rising edge starts a 10s flash window; afterwards the state may
            // persist (still waiting) but the flashing stops
            if attention && !claudePrevAttention { claudeAttentionSince = Date() }
            claudePrevAttention = attention
            if attention, !persistentAttention, let since = claudeAttentionSince,
               Date().timeIntervalSince(since) >= flashDuration {
                attention = false
            }
        }
        return AgentUsage(available: true, todayInputTokens: claudeInput,
                          todayOutputTokens: claudeOutput,
                          secondsSinceActive: secondsAgo,
                          project: project, activity: activity,
                          needsAttention: attention, isWorking: working,
                          waitingFor: waitingFor, model: model,
                          stepCurrent: step?.current, stepTotal: step?.total,
                          stepText: step?.text)
    }

    // MARK: - Claude live session state

    /// What Claude Code publishes about a running session in
    /// `~/.claude/sessions/<pid>.json`. `status` is one of busy / shell / idle /
    /// waiting; `waitingFor` explains a `waiting` — "permission prompt",
    /// "input needed", "dialog open", "sandbox request", "worker request".
    private struct ClaudeSessionState {
        let status: String
        let waitingFor: String?
        let statusUpdatedAt: Date?

        /// Blocked on the user, and recently enough to still be worth surfacing.
        /// The staleness bound matches the transcript path: a prompt you walked
        /// away from an hour ago must not pin the panel or flash forever.
        var isBlocked: Bool {
            guard status == "waiting" else { return false }
            guard let at = statusUpdatedAt else { return true }
            return Date().timeIntervalSince(at) < 900
        }
    }

    /// sessionId → live state, for sessions whose CLI process is still alive.
    /// A handful of small JSON files, so this is re-read each tick rather than cached.
    private func claudeSessionStates() -> [String: ClaudeSessionState] {
        let dir = home + "/.claude/sessions"
        var out: [String: ClaudeSessionState] = [:]
        for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            guard file.hasSuffix(".json"),
                  let data = fm.contents(atPath: dir + "/" + file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let status = obj["status"] as? String
            else { continue }
            // Ignore records orphaned by a crashed CLI — their last-written status
            // would otherwise pin the column to "working" or "waiting" forever.
            if let pid = (obj["pid"] as? NSNumber)?.int32Value,
               kill(pid, 0) != 0, errno == ESRCH { continue }
            // statusUpdatedAt is epoch milliseconds
            let updated = (obj["statusUpdatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            out[sid] = ClaudeSessionState(status: status,
                                          waitingFor: obj["waitingFor"] as? String,
                                          statusUpdatedAt: updated)
        }
        return out
    }

    private func accumulateClaudeLine(_ line: String) {
        guard let obj = parseJSON(line),
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else { return }
        // Dedupe: continued/forked sessions copy earlier entries into new files
        if let id = msg["id"] as? String {
            guard claudeSeenIDs.insert(id).inserted else { return }
        }
        claudeInput += uint(usage["input_tokens"])
            + uint(usage["cache_creation_input_tokens"])
            + uint(usage["cache_read_input_tokens"])
        claudeOutput += uint(usage["output_tokens"])
    }

    /// From the tail of the most recent session: project, the last thing Claude SAID
    /// (its latest text block, markdown preserved — never tool calls), the flash state,
    /// and TodoWrite plan progress.
    /// Attention heuristic: the LAST significant main-chain entry decides —
    ///   assistant text-only  → turn ended, Claude is waiting for the user → true
    ///   assistant tool_use   → still working → false
    ///   user-typed message   → user already responded → false
    private func claudeActivity(path: String)
        -> (project: String?, activity: String?, attention: Bool,
            step: (current: Int, total: Int, text: String)?, model: String?) {
        var project: String?
        var model: String?
        var message: String?
        var attention = false
        var stateDetermined = false
        var crossedUserTurn = false   // scanned past a real user message → older todos are stale
        var step: (Int, Int, String)?
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            let isAssistant = line.contains("\"type\":\"assistant\"")
            let isUser = line.contains("\"type\":\"user\"")
            guard isAssistant || isUser, let obj = parseJSON(line) else { continue }
            // Subagent side chains don't reflect the main conversation state
            if obj["isSidechain"] as? Bool == true { continue }

            if isUser, obj["type"] as? String == "user" {
                // A real user message (not a tool_result) is a turn boundary: a
                // TodoWrite older than it belongs to a finished request → stale.
                if isRealUserMessage(obj) { crossedUserTurn = true }
                if !stateDetermined {
                    attention = false
                    stateDetermined = true
                }
                continue
            }

            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { continue }
            if project == nil, let cwd = obj["cwd"] as? String {
                project = (cwd as NSString).lastPathComponent
            }
            // Newest assistant entry wins — reflects a mid-session /model switch
            if model == nil, let m = msg["model"] as? String { model = m }
            var sawToolUse = false
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        sawToolUse = true
                        // TodoWrite from the CURRENT turn only (before any user boundary)
                        if step == nil, !crossedUserTurn,
                           block["name"] as? String == "TodoWrite",
                           let input = block["input"] as? [String: Any],
                           let todos = input["todos"] as? [[String: Any]] {
                            step = parseClaudeTodos(todos)
                        }
                    case "text":
                        // The message Claude spoke — markdown preserved for table layout
                        if message == nil {
                            let t = cleanMultiline(block["text"] as? String ?? "")
                            if !t.isEmpty { message = t }
                        }
                    default:
                        break
                    }
                }
            }
            if !stateDetermined {
                attention = !sawToolUse   // text-only final message → your turn
                stateDetermined = true
            }
            // Stop once the message + state are known and the step is either found
            // or can no longer appear (we've passed the current user turn)
            if message != nil && stateDetermined && (step != nil || crossedUserTurn) { break }
        }
        return (project, message, attention, step, model)
    }

    /// A real user request, as opposed to a tool_result the harness feeds back mid-turn.
    private func isRealUserMessage(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any] else { return false }
        if msg["content"] is String { return true }
        if let content = msg["content"] as? [[String: Any]] {
            return content.contains { ($0["type"] as? String) != "tool_result" }
        }
        return false
    }

    /// Claude TodoWrite todos → (currentStep, totalSteps, text). Same rule as Codex.
    private func parseClaudeTodos(_ todos: [[String: Any]]) -> (Int, Int, String)? {
        let items = todos.compactMap { t -> (text: String, status: String)? in
            guard let content = t["content"] as? String,
                  let status = t["status"] as? String else { return nil }
            let active = t["activeForm"] as? String
            return (status == "in_progress" ? (active ?? content) : content, status)
        }
        guard !items.isEmpty else { return nil }
        let total = items.count
        if let i = items.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(items[i].text))
        }
        if let i = items.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(items[i].text))
        }
        return (total, total, clean(items.last?.text ?? ""))
    }

    // MARK: - Codex

    private func collectCodex() -> AgentUsage {
        let root = home + "/.codex/sessions"
        guard fm.fileExists(atPath: root) else {
            return AgentUsage(available: false, todayInputTokens: 0, todayOutputTokens: 0,
                              secondsSinceActive: nil, project: nil, activity: nil)
        }

        // Session dirs are keyed by START date. Scan a rolling window of recent
        // days: today+yesterday for token counting (a session can span midnight),
        // plus older days only to locate the most recent session for the
        // activity/quota display when nothing has run today.
        let todayStart = Calendar.current.startOfDay(for: Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        var dirs: [String] = []
        for back in 0..<14 {
            if let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) {
                dirs.append(root + "/" + df.string(from: d))
            }
        }

        var latestPath: String?
        var latestMtime = Date.distantPast

        for dir in dirs {
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }
                // Latest session overall — drives activity/quota display
                if mtime > latestMtime { latestMtime = mtime; latestPath = path }

                // Token counting is scoped to today only
                guard mtime >= todayStart else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                consumeNewLines(path: path, size: size, offsets: &codexOffsets,
                                prefilter: "\"token_count\"") { line in
                    self.accumulateCodexLine(line)
                }
            }
        }

        // Live weekly quota from ChatGPT (async, throttled). See updateCodexQuota().
        updateCodexQuota()

        var project: String?
        var activity: String?
        var secondsAgo: Int?
        codexQuotaLock.lock()
        let quotaUsed = codexQuotaCache?.used
        let quotaResets = codexQuotaCache?.resets
        codexQuotaLock.unlock()
        var attention = false
        var working = false
        var model: String?
        var step: (current: Int, total: Int, text: String)?
        if let path = latestPath {
            let ago = max(0, Int(Date().timeIntervalSince(latestMtime)))
            secondsAgo = ago
            let rawWaiting: Bool
            (project, activity, rawWaiting) = codexActivity(path: path)
            step = codexPlan(path: path)
            model = codexModel(path: path)
            // Actively running = not waiting on the user AND the file just changed
            working = !rawWaiting && ago < 90
            attention = rawWaiting && ago < 900
            if attention && !codexPrevAttention { codexAttentionSince = Date() }
            codexPrevAttention = attention
            if attention, let since = codexAttentionSince,
               Date().timeIntervalSince(since) >= flashDuration {
                attention = false
            }
        }
        return AgentUsage(available: true, todayInputTokens: codexInput,
                          todayOutputTokens: codexOutput,
                          secondsSinceActive: secondsAgo,
                          project: project, activity: activity,
                          quotaUsedPercent: quotaUsed, quotaResetsAt: quotaResets,
                          needsAttention: attention, isWorking: working,
                          model: model,
                          stepCurrent: step?.current, stepTotal: step?.total,
                          stepText: step?.text)
    }

    /// Last known model per session file. The activity scan stops as soon as it has
    /// the message and state, which is usually well short of the newest
    /// `turn_context`, so the model needs its own targeted lookup — and the cache
    /// keeps the label stable on a tick where that lookup comes up empty.
    private var codexModelCache: [String: String] = [:]

    /// Active model, from the newest `turn_context` record (written once per turn).
    /// Its discriminator lives at the top level, not inside `payload`.
    private func codexModel(path: String) -> String? {
        if let line = lastLine(path: path, containing: "\"turn_context\"",
                               maxScan: 512 * 1024),
           let obj = parseJSON(line),
           obj["type"] as? String == "turn_context",
           let payload = obj["payload"] as? [String: Any],
           let m = payload["model"] as? String {
            codexModelCache[path] = m
        }
        return codexModelCache[path]
    }

    /// Active `update_plan` → (currentStep, totalSteps, stepText), or nil.
    /// A plan only counts as CURRENT if it's newer than the last `task_complete`:
    /// once the planned task finished and a new turn began without its own plan, the
    /// stale plan must not linger on screen. Scanning newest-first, whichever comes
    /// first — a plan update or a task completion — decides.
    private func codexPlan(path: String) -> (current: Int, total: Int, text: String)? {
        for line in tailLines(path: path, maxBytes: 512 * 1024).reversed() {
            let maybePlan = line.contains("update_plan")
            let maybeDone = line.contains("\"task_complete\"")
            guard maybePlan || maybeDone,
                  let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any]
            else { continue }

            // Newest turn already ended → no active plan
            if payload["type"] as? String == "task_complete" { return nil }

            // Two plan encodings across Codex versions:
            //  · custom_tool_call → `input`: JS source `tools.update_plan({plan:[…]})`
            //  · function_call    → `arguments`: JSON `{"plan":[…]}` (name == update_plan)
            if let input = payload["input"] as? String, input.contains("update_plan") {
                return parseCodexPlan(input)
            }
            if payload["name"] as? String == "update_plan",
               let args = payload["arguments"] as? String {
                return parseCodexPlan(args)
            }
        }
        return nil
    }

    private func parseCodexPlan(_ input: String) -> (Int, Int, String)? {
        // Ordered [(step, status)] from the plan array. Key quoting is inconsistent
        // across Codex versions — `step:"…"` unquoted, `"status":"…"` quoted, or
        // vice-versa — so match each `{step, status}` pair with tolerant quoting.
        let pattern = "\"?step\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*"
            + "\"?status\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let steps: [(text: String, status: String)] = matches.map {
            (unescapeJS(ns.substring(with: $0.range(at: 1))),
             ns.substring(with: $0.range(at: 2)))
        }
        let total = steps.count
        // Current = the in_progress step; else the first not-yet-done step; else all done
        if let i = steps.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        if let i = steps.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        return (total, total, clean(steps.last?.text ?? ""))
    }

    private func unescapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Refresh the weekly Codex subscription quota from ChatGPT's live API:
    ///   GET https://chatgpt.com/backend-api/wham/usage
    /// using the OAuth tokens in `~/.codex/auth.json` (same source as the Codex
    /// client and `tokens codex status`). Session-file `rate_limits` blocks are
    /// intentionally ignored — they lag the server and can show 100% used while
    /// the real weekly window still has capacity (e.g. client shows 87% left).
    ///
    /// Network fetch is async + throttled (~60s). Until the first reply lands,
    /// `codexQuotaCache` stays nil and the panel simply hides the quota bar.
    private func updateCodexQuota() {
        codexQuotaLock.lock()
        if let last = codexQuotaLastFetch, Date().timeIntervalSince(last) < 60 {
            codexQuotaLock.unlock()
            return
        }
        if codexQuotaInFlight {
            codexQuotaLock.unlock()
            return
        }
        codexQuotaInFlight = true
        codexQuotaLock.unlock()

        // Snapshot auth on this thread (FileManager is fine off-main).
        let authPath = home + "/.codex/auth.json"
        guard let data = fm.contents(atPath: authPath),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else {
            codexQuotaLock.lock()
            codexQuotaInFlight = false
            codexQuotaLastFetch = Date()   // back off even on missing auth
            codexQuotaLock.unlock()
            return
        }
        let accountID = tokens["account_id"] as? String ?? ""

        // Fire-and-forget on a utility queue so the metrics loop never blocks
        // on the network. Result is published into codexQuotaCache under lock.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.codexQuotaLock.lock()
                self?.codexQuotaInFlight = false
                self?.codexQuotaLastFetch = Date()
                self?.codexQuotaLock.unlock()
            }
            guard let self else { return }
            guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")
            else { return }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                         forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if !accountID.isEmpty {
                req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            let sem = DispatchSemaphore(value: 0)
            var body: Data?
            URLSession.shared.dataTask(with: req) { data, _, _ in
                body = data
                sem.signal()
            }.resume()
            // Cap wait so a hung request can't pin the utility thread forever
            _ = sem.wait(timeout: .now() + 15)
            guard let body,
                  let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let rate = obj["rate_limit"] as? [String: Any],
                  let primary = rate["primary_window"] as? [String: Any],
                  let used = (primary["used_percent"] as? NSNumber)?.doubleValue
            else { return }
            var resets: Date?
            if let r = (primary["reset_at"] as? NSNumber)?.doubleValue {
                resets = Date(timeIntervalSince1970: r)
            } else if let after = (primary["reset_after_seconds"] as? NSNumber)?.doubleValue {
                resets = Date().addingTimeInterval(after)
            }
            self.codexQuotaLock.lock()
            self.codexQuotaCache = (used, resets)
            self.codexQuotaLock.unlock()
        }
    }

    /// Sum per-request deltas (`last_token_usage`), NOT `total_token_usage`.
    /// `input_tokens` already includes the cached prefix of the context window
    /// (this is the historical MacTR / tokens-service style total — full context
    /// seen each turn, not "new tokens only").
    private func accumulateCodexLine(_ line: String) {
        guard let obj = parseJSON(line),
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }
        // input_tokens already includes cached_input_tokens; cache writes are separate
        codexInput += uint(last["input_tokens"]) + uint(last["cache_write_input_tokens"])
        codexOutput += uint(last["output_tokens"])
    }

    /// (project, activity, needsAttention). Attention: the last significant event is
    /// task_complete (done) or an approval request (waiting for the user); a newer
    /// user message or a running tool call cancels it.
    private func codexActivity(path: String) -> (String?, String?, Bool) {
        // cwd lives in the head session_meta line, but that line embeds the full
        // system prompt (tens of KB) so a JSON parse would need the whole line.
        // cwd appears before the prompt, so pull it by substring from a head chunk.
        var project: String?
        if let head = tailLines(path: path, maxBytes: 0, headBytes: 16 * 1024).first,
           let cwd = extractJSONString(head, key: "cwd") {
            project = (cwd as NSString).lastPathComponent
        }

        // Working signals (Codex is mid-turn) vs waiting signals (turn ended /
        // needs the user). Newest-first, the first of either decides — so an active
        // command after a prior task_complete correctly reads as "working", not "wait".
        // token_count is ignored for state: it fires after every response, including
        // the final one, and would mask the real last event.
        let workingTypes: Set<String> = [
            "custom_tool_call", "custom_tool_call_output", "function_call",
            "function_call_output", "agent_reasoning", "reasoning",
            "task_started", "user_message",
        ]
        // Activity = the last thing Codex SAID (agent_message / task_complete text),
        // never the shell commands it ran. If no message exists in the window (a long
        // command-only stretch), fall back to the latest reasoning title.
        var message: String?
        var reasoning: String?
        var attention = false
        var stateDetermined = false
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            guard let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            if !stateDetermined {
                if type == "task_complete" || type.contains("approval_request") {
                    attention = true; stateDetermined = true
                } else if workingTypes.contains(type)
                            || (type == "message" && payload["role"] as? String == "user") {
                    attention = false; stateDetermined = true
                }
            }

            if message == nil {
                switch type {
                case "agent_message":
                    // Keep newlines/markdown so the renderer can lay out tables & lists
                    message = cleanMultiline(payload["message"] as? String ?? "")
                case "task_complete":
                    message = cleanMultiline(payload["last_agent_message"] as? String ?? "")
                default:
                    break
                }
                if message?.isEmpty == true { message = nil }
            }
            if reasoning == nil, type == "agent_reasoning" {
                let t = (payload["text"] as? String ?? "")
                    .replacingOccurrences(of: "**", with: "")
                let c = clean(t)
                if !c.isEmpty { reasoning = c }
            }

            if message != nil && stateDetermined { break }
        }
        let activity = message ?? reasoning
        return (project, activity, attention)
    }

    // MARK: - Cursor

    /// Cursor agent transcripts live at
    /// `~/.cursor/projects/<proj>/agent-transcripts/<uuid>/<uuid>.jsonl`.
    /// Each line is either a `{role, message}` turn (Claude-shaped content
    /// blocks) or a `{type:"turn_ended", status}` marker.
    ///
    /// Per-message token totals are zeroed even in Cursor's IDE DB, so the
    /// "今日 Token" number stays blank. What we *can* surface is the active
    /// conversation's `contextUsagePercent` from
    /// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
    /// (composerHeaders) — shown as the bottom quota-style bar.
    private func collectCursor() -> AgentUsage {
        let root = home + "/.cursor/projects"
        guard fm.fileExists(atPath: root) else {
            return AgentUsage(available: false, todayInputTokens: 0, todayOutputTokens: 0,
                              secondsSinceActive: nil, project: nil, activity: nil)
        }

        var latestPath: String?
        var latestMtime = Date.distantPast
        var latestProject: String?
        var latestSessionID: String?

        for projDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            // Skip housekeeping markers like `.agent-data-cleanup-…`
            if projDir.hasPrefix(".") { continue }
            let transcripts = root + "/" + projDir + "/agent-transcripts"
            guard fm.fileExists(atPath: transcripts) else { continue }
            for sid in (try? fm.contentsOfDirectory(atPath: transcripts)) ?? [] {
                // Prefer the primary transcript over subagent side chains
                let path = transcripts + "/" + sid + "/" + sid + ".jsonl"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }
                if mtime > latestMtime {
                    latestMtime = mtime
                    latestPath = path
                    latestProject = projDir
                    latestSessionID = sid
                }
            }
        }

        var project: String?
        var activity: String?
        var secondsAgo: Int?
        var attention = false
        var working = false
        var model: String?
        var step: (current: Int, total: Int, text: String)?
        var contextUsed: Double?

        if let path = latestPath {
            let ago = max(0, Int(Date().timeIntervalSince(latestMtime)))
            secondsAgo = ago
            let rawWaiting: Bool
            (project, activity, rawWaiting, step, model) = cursorActivity(path: path)
            // Project dir is encoded as `Users-ming-Documents-foo` — fall back to
            // the last path segment of that slug when the transcript itself has
            // no cwd (Cursor doesn't write one).
            if project == nil, let slug = latestProject {
                project = cursorProjectName(from: slug)
            }
            // Same 90s "still writing" / 900s "recently done" windows as Codex
            working = !rawWaiting && ago < 90
            attention = rawWaiting && ago < 900
            if attention && !cursorPrevAttention { cursorAttentionSince = Date() }
            cursorPrevAttention = attention
            if attention, let since = cursorAttentionSince,
               Date().timeIntervalSince(since) >= flashDuration {
                attention = false
            }
            // Context-window fill of the active composer (not a daily token total)
            contextUsed = cursorContextUsage(sessionID: latestSessionID)
            if model == nil {
                model = cursorModelFromTracking(sessionID: latestSessionID)
            }
        }

        return AgentUsage(available: true, todayInputTokens: 0, todayOutputTokens: 0,
                          secondsSinceActive: secondsAgo,
                          project: project, activity: activity,
                          // Reuse the quota bar as "context used %" — label is
                          // overridden in the renderer when hasTokenUsage is false.
                          quotaUsedPercent: contextUsed,
                          needsAttention: attention, isWorking: working,
                          model: model,
                          stepCurrent: step?.current, stepTotal: step?.total,
                          stepText: step?.text,
                          hasTokenUsage: false)
    }

    /// `contextUsagePercent` of the matching (or newest) composer header in
    /// Cursor's state.vscdb. Cheap: one SQLite read of the small composerHeaders
    /// table. Returns nil when Cursor isn't installed or the table is empty.
    private func cursorContextUsage(sessionID: String?) -> Double? {
        let dbPath = home
            + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard fm.fileExists(atPath: dbPath) else { return nil }
        // sqlite3 CLI is always present on macOS; avoids linking libsqlite.
        // Prefer the row whose composerId matches the active transcript, else
        // the most recently updated non-draft header with a context figure.
        // Two single-line queries (Process passes one arg; multi-statement /
        // UNION…ORDER BY on a single-column projection fails in sqlite3).
        var candidates: [String] = []
        if let sid = sessionID, sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            candidates.append(
                "SELECT value FROM composerHeaders WHERE composerId = '\(sid)' LIMIT 1;")
        }
        candidates.append(
            "SELECT value FROM composerHeaders ORDER BY COALESCE(lastUpdatedAt, recency) DESC LIMIT 8;")
        for sql in candidates {
            guard let out = runSQLite(db: dbPath, sql: sql) else { continue }
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = parseJSON(String(line)) else { continue }
                if obj["isDraft"] as? Bool == true { continue }
                if obj["isEphemeral"] as? Bool == true { continue }
                if let pct = (obj["contextUsagePercent"] as? NSNumber)?.doubleValue {
                    return pct
                }
            }
        }
        return nil
    }

    /// Best-effort model id from `~/.cursor/ai-tracking/ai-code-tracking.db`
    /// (rows written when Cursor applies code). Filtered by conversationId when
    /// we know it; otherwise the most recent row overall.
    private func cursorModelFromTracking(sessionID: String?) -> String? {
        let dbPath = home + "/.cursor/ai-tracking/ai-code-tracking.db"
        guard fm.fileExists(atPath: dbPath) else { return nil }
        let sql: String
        if let sid = sessionID, sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            sql = """
            SELECT model FROM ai_code_hashes
            WHERE conversationId = '\(sid)' AND model IS NOT NULL AND model != ''
            ORDER BY timestamp DESC LIMIT 1;
            """
        } else {
            sql = """
            SELECT model FROM ai_code_hashes
            WHERE model IS NOT NULL AND model != ''
            ORDER BY timestamp DESC LIMIT 1;
            """
        }
        guard let out = runSQLite(db: dbPath, sql: sql) else { return nil }
        let model = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    /// Run a read-only SQL query via `/usr/bin/sqlite3`. Returns stdout, or nil
    /// on any failure. Kept process-free of network; the DBs are local only.
    private func runSQLite(db: String, sql: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // -readonly ensures we never lock Cursor out of its own DB
        proc.arguments = ["-readonly", db, sql]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Decode `Users-ming-Documents-ad-test-mini` → `ad-test-mini`. Best-effort:
    /// take the last path-ish segment after common home prefixes.
    private func cursorProjectName(from slug: String) -> String {
        // Common encoding: absolute path with `/` → `-`
        // e.g. Users-ming-Documents-foo-bar → foo-bar
        let markers = ["Users-\(NSUserName())-Documents-",
                       "Users-\(NSUserName())-",
                       "home-\(NSUserName())-"]
        for m in markers {
            if let r = slug.range(of: m) {
                let rest = String(slug[r.upperBound...])
                if !rest.isEmpty { return rest }
            }
        }
        // Fall back to the last 2 dash-separated tokens if the slug is long
        let parts = slug.split(separator: "-")
        if parts.count >= 2 { return parts.suffix(2).joined(separator: "-") }
        return slug
    }

    /// Tail of a Cursor transcript → project, last assistant text, attention,
    /// TodoWrite plan, model. Attention: a trailing `turn_ended` means the
    /// agent is waiting for the user; a trailing tool_use without one means
    /// it's still mid-turn.
    private func cursorActivity(path: String)
        -> (project: String?, activity: String?, attention: Bool,
            step: (current: Int, total: Int, text: String)?, model: String?) {
        var message: String?
        var attention = false
        var stateDetermined = false
        var crossedUserTurn = false
        var step: (Int, Int, String)?
        var model: String?

        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            // turn_ended is the clean "your turn" marker Cursor writes
            if line.contains("\"turn_ended\"") {
                if let obj = parseJSON(line), obj["type"] as? String == "turn_ended" {
                    if !stateDetermined {
                        attention = true
                        stateDetermined = true
                    }
                }
                continue
            }

            let isAssistant = line.contains("\"role\":\"assistant\"")
            let isUser = line.contains("\"role\":\"user\"")
            guard isAssistant || isUser, let obj = parseJSON(line) else { continue }

            if isUser, obj["role"] as? String == "user" {
                crossedUserTurn = true
                if !stateDetermined {
                    // User already spoke after the agent → not waiting
                    attention = false
                    stateDetermined = true
                }
                continue
            }

            guard obj["role"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { continue }

            if model == nil, let m = msg["model"] as? String { model = m }

            var sawToolUse = false
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        sawToolUse = true
                        if step == nil, !crossedUserTurn,
                           block["name"] as? String == "TodoWrite",
                           let input = block["input"] as? [String: Any],
                           let todos = input["todos"] as? [[String: Any]] {
                            // Cursor uses the same TodoWrite shape as Claude
                            step = parseClaudeTodos(todos)
                        }
                    case "text":
                        if message == nil {
                            let t = cleanMultiline(block["text"] as? String ?? "")
                            // Strip the synthetic <timestamp>…</timestamp> /
                            // <user_query> wrappers Cursor injects into some
                            // user-echoed text so the panel shows real prose.
                            let stripped = stripCursorWrappers(t)
                            if !stripped.isEmpty { message = stripped }
                        }
                    default:
                        break
                    }
                }
            }

            if !stateDetermined {
                // No turn_ended yet: tool_use → still working; text-only → done
                attention = !sawToolUse
                stateDetermined = true
            }

            if message != nil && stateDetermined && (step != nil || crossedUserTurn) {
                break
            }
        }
        return (nil, message, attention, step, model)
    }

    /// Drop Cursor's synthetic XML wrappers so the panel shows the real text.
    private func stripCursorWrappers(_ s: String) -> String {
        var t = s
        // <timestamp>…</timestamp> and <user_query>…</user_query>
        if let re = try? NSRegularExpression(
            pattern: "</?(timestamp|user_query|system_reminder)[^>]*>",
            options: [.caseInsensitive]
        ) {
            t = re.stringByReplacingMatches(
                in: t, range: NSRange(location: 0, length: (t as NSString).length),
                withTemplate: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull a JSON string value by key via substring scan — cheaper than parsing,
    /// and works on a truncated head chunk or embedded JS source.
    private func extractJSONString(_ s: String, key: String) -> String? {
        guard let r = s.range(of: "\"\(key)\":\"") else { return nil }
        let out = readJSString(s, from: r.upperBound)
        return out.isEmpty ? nil : out
    }

    /// Read a double-quoted string value starting just after the opening quote.
    /// Resolves \" \\ \n \t and stops at the closing unescaped quote.
    private func readJSString(_ s: String, from start: String.Index) -> String {
        var out = ""
        var i = start
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                switch c {
                case "n", "t": out.append(" ")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - File Helpers

    /// Feed complete NEW lines (since the stored offset) matching `prefilter`
    /// to `handler`, then advance the offset past the last complete line.
    private func consumeNewLines(path: String, size: UInt64,
                                 offsets: inout [String: UInt64],
                                 prefilter: String,
                                 handler: (String) -> Void) {
        var offset = offsets[path] ?? 0
        if size < offset { offset = 0 }  // truncated/rotated — dedupe absorbs re-reads
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }

        // Only consume up to the last newline — the writer may be mid-line
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offsets[path] = offset + UInt64(lastNL) + 1

        let complete = data[data.startIndex...lastNL]
        for chunk in complete.split(separator: UInt8(ascii: "\n")) {
            guard let line = String(data: Data(chunk), encoding: .utf8),
                  line.contains(prefilter)
            else { continue }
            handler(line)
        }
    }

    /// Newest line containing `needle`, scanning backwards from EOF in chunks.
    /// Session transcripts run to tens of MB but the line we want sits within a
    /// megabyte of the end, so reading the whole file to find it costs ~10x more
    /// memory than the answer is worth. Chunked scanning keeps the peak at
    /// `chunk` bytes no matter how large the file grows.
    private func lastLine(path: String, containing needle: String,
                          chunk: Int = 256 * 1024,
                          maxScan: Int = 4 * 1024 * 1024) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        var end = size                      // exclusive upper bound of the window
        var scanned = 0
        // Carry the partial line at the window's start into the next (earlier)
        // window, so a line straddling a chunk boundary is never split.
        var carry = Data()

        while end > 0 && scanned < maxScan {
            let start = end > UInt64(chunk) ? end - UInt64(chunk) : 0
            try? fh.seek(toOffset: start)
            guard var data = try? fh.read(upToCount: Int(end - start)), !data.isEmpty
            else { return nil }
            data.append(carry)
            scanned += Int(end - start)

            // Everything before the first newline is a partial line — defer it.
            let bodyStart: Data.Index
            if start == 0 {
                bodyStart = data.startIndex
                carry = Data()
            } else if let firstNL = data.firstIndex(of: UInt8(ascii: "\n")) {
                bodyStart = data.index(after: firstNL)
                carry = data[data.startIndex..<firstNL]
            } else {
                carry = data          // no newline at all — keep growing the carry
                end = start
                continue
            }

            for chunkLine in data[bodyStart...].split(separator: UInt8(ascii: "\n")).reversed() {
                guard let line = String(data: Data(chunkLine), encoding: .utf8),
                      line.contains(needle)
                else { continue }
                return line
            }
            end = start
        }
        return nil
    }

    /// Read complete lines from the tail (or head, if headBytes > 0) of a file.
    private func tailLines(path: String, maxBytes: Int, headBytes: Int = 0) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let data: Data
        if headBytes > 0 {
            data = (try? fh.read(upToCount: headBytes)) ?? Data()
        } else {
            let size = (try? fh.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? fh.seek(toOffset: start)
            data = (try? fh.readToEnd()) ?? Data()
        }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func uint(_ v: Any?) -> UInt64 {
        (v as? NSNumber)?.uint64Value ?? 0
    }

    /// Single line, capped length — display truncation happens at render time
    private func clean(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
    }

    /// Multi-line preserving — keeps newlines/markdown structure (tables, lists)
    /// for the renderer to lay out. Caps length so a huge message can't dominate.
    private func cleanMultiline(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 800 ? String(trimmed.prefix(800)) + "…" : trimmed
    }
}
