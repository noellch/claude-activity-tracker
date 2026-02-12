import Foundation
import Combine

// MARK: - Session Info

struct SessionInfo: Identifiable {
    let id: String
    let projectPath: String
    let projectName: String
    let filePath: String
    let startTime: Date?
    let endTime: Date?
    let messageCount: Int
    let humanMessageCount: Int
    let assistantMessageCount: Int
    let genuineHumanMessages: [String]
    let keyAssistantMessages: [String]
    let filesModified: Set<String>
    let commandsRun: [String]
    let summary: String?
    let cwd: String?

    /// Active duration: only counts time between messages with gaps ≤ 30 min
    let activeDuration: TimeInterval

    var duration: TimeInterval {
        return activeDuration
    }

    var durationFormatted: String {
        let mins = Int(duration / 60)
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    var bestDescription: String {
        if let first = genuineHumanMessages.first, !first.isEmpty { return first }
        if let first = keyAssistantMessages.first, !first.isEmpty { return first }
        if let s = summary, !s.isEmpty { return s }
        return "Coding session"
    }
}

struct DayStats {
    var totalSessions: Int = 0
    var totalMessages: Int = 0
    var totalHumanMessages: Int = 0
    var totalDuration: TimeInterval = 0
    var sessions: [SessionInfo] = []
    var projectBreakdown: [String: Int] = [:]

    var totalDurationFormatted: String {
        let mins = Int(totalDuration / 60)
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}

// MARK: - Activity Monitor

class ClaudeActivityMonitor: ObservableObject {
    @Published var todayStats = DayStats()
    @Published var weekStats: [Date: DayStats] = [:]
    @Published var isLoading = false
    @Published var lastRefresh: Date?

    private let claudeDir: String
    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterNoFrac: ISO8601DateFormatter

    /// Cache: filePath -> (modificationDate, parsedSession)
    private var sessionCache: [String: (Date, SessionInfo)] = [:]

    /// File watchers for auto-refresh
    private var directoryWatchers: [Int32: DispatchSourceFileSystemObject] = [:]
    private var watchedDescriptors: [Int32] = []
    private var lastAutoRefresh = Date.distantPast

    /// Called after each refresh completes (on main thread)
    var onRefreshComplete: (() -> Void)?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(home)/.claude"

        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.isoFormatterNoFrac = ISO8601DateFormatter()
        self.isoFormatterNoFrac.formatOptions = [.withInternetDateTime]
    }

    // MARK: - File Watcher

    func startWatching() {
        stopWatching()
        let projectsDir = "\(claudeDir)/projects"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for projectDir in projectDirs {
            if isExcludedPath(projectDir) { continue }
            let fullPath = "\(projectsDir)/\(projectDir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
            watchDirectory(fullPath)
        }
        // Also watch the top-level projects dir for new project folders
        watchDirectory(projectsDir)
    }

    func stopWatching() {
        for (_, source) in directoryWatchers {
            source.cancel()
        }
        for fd in watchedDescriptors {
            close(fd)
        }
        directoryWatchers.removeAll()
        watchedDescriptors.removeAll()
    }

    private func watchDirectory(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptors.append(fd)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.onDirectoryChanged()
        }
        source.setCancelHandler {
            // fd closed in stopWatching
        }
        source.resume()
        directoryWatchers[fd] = source
    }

    private func onDirectoryChanged() {
        // Debounce: ignore events within 3 seconds of last refresh
        let now = Date()
        guard now.timeIntervalSince(lastAutoRefresh) > 3 else { return }
        lastAutoRefresh = now

        // Small delay to let the file finish writing
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        stopWatching()
    }

    func refresh() {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let today = Calendar.current.startOfDay(for: Date())
            let sessions = self.loadAllSessions()

            let todaySessions = sessions.filter { s in
                guard let start = s.startTime else { return false }
                return Calendar.current.isDate(start, inSameDayAs: today)
            }

            var stats = DayStats()
            stats.totalSessions = todaySessions.count
            stats.sessions = todaySessions.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
            stats.totalMessages = todaySessions.reduce(0) { $0 + $1.messageCount }
            stats.totalHumanMessages = todaySessions.reduce(0) { $0 + $1.humanMessageCount }
            stats.totalDuration = todaySessions.reduce(0) { $0 + $1.duration }

            for s in todaySessions {
                stats.projectBreakdown[s.projectName, default: 0] += 1
            }

            var weekData: [Date: DayStats] = [:]
            for i in 0..<7 {
                let day = Calendar.current.date(byAdding: .day, value: -i, to: today)!
                let daySessions = sessions.filter { s in
                    guard let start = s.startTime else { return false }
                    return Calendar.current.isDate(start, inSameDayAs: day)
                }
                var dayStats = DayStats()
                dayStats.totalSessions = daySessions.count
                dayStats.sessions = daySessions
                dayStats.totalMessages = daySessions.reduce(0) { $0 + $1.messageCount }
                dayStats.totalHumanMessages = daySessions.reduce(0) { $0 + $1.humanMessageCount }
                dayStats.totalDuration = daySessions.reduce(0) { $0 + $1.duration }
                for s in daySessions {
                    dayStats.projectBreakdown[s.projectName, default: 0] += 1
                }
                weekData[day] = dayStats
            }

            DispatchQueue.main.async {
                self.todayStats = stats
                self.weekStats = weekData
                self.isLoading = false
                self.lastRefresh = Date()
                self.onRefreshComplete?()
            }
        }
    }

    // MARK: - Load Sessions

    private static let excludedPathPatterns = [
        "claude-mem",
        "mem-observer",
        "observer-sessions",
        "double-shot",
        "claude-double-shot",
        "/subagents",
    ]

    private func isExcludedPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return Self.excludedPathPatterns.contains { lowered.contains($0) }
    }

    private func loadAllSessions() -> [SessionInfo] {
        let projectsDir = "\(claudeDir)/projects"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        var allSessions: [SessionInfo] = []
        var seenPaths: Set<String> = []

        for projectDir in projectDirs {
            if isExcludedPath(projectDir) { continue }

            let projectPath = "\(projectsDir)/\(projectDir)"

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            let jsonlFiles = files.filter {
                $0.hasSuffix(".jsonl") && !$0.hasPrefix("agent-")
            }

            let projectName = extractProjectName(from: projectDir)

            for file in jsonlFiles {
                let filePath = "\(projectPath)/\(file)"
                let sessionId = String(file.dropLast(6))
                seenPaths.insert(filePath)

                // Check cache by file modification date
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date,
                   let cached = sessionCache[filePath],
                   cached.0 == modDate {
                    allSessions.append(cached.1)
                    continue
                }

                // Cache miss — parse and store
                let modDate = (try? fm.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date ?? Date()

                if let session = parseSession(
                    id: sessionId, filePath: filePath,
                    projectPath: projectDir, projectName: projectName
                ) {
                    if session.humanMessageCount > 0 || session.assistantMessageCount > 1 {
                        sessionCache[filePath] = (modDate, session)
                        allSessions.append(session)
                    }
                }
            }
        }

        // Evict deleted files from cache
        for key in sessionCache.keys where !seenPaths.contains(key) {
            sessionCache.removeValue(forKey: key)
        }

        return allSessions
    }

    // MARK: - Parse Session (Full Scan)

    private func parseSession(id: String, filePath: String, projectPath: String, projectName: String) -> SessionInfo? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var prevTimestamp: Date?
        var activeTime: TimeInterval = 0
        let maxGap: TimeInterval = 30 * 60  // 30 minutes
        var messageCount = 0
        var humanMessageCount = 0
        var assistantMessageCount = 0
        var genuineHumanMessages: [String] = []
        var keyAssistantMessages: [String] = []
        var filesModified: Set<String> = []
        var commandsRun: [String] = []
        var summaryText: String?
        var sessionCwd: String?

        let maxHumanMessages = 10
        let maxAssistantMessages = 5
        let maxCommands = 5

        for line in lines {
            // For progress/queue-operation lines: only extract timestamp (cheap), skip full parse
            if line.contains("\"type\":\"progress\"") || line.contains("\"type\":\"queue-operation\"") {
                if let ts = extractTimestampCheap(from: line) {
                    if firstTimestamp == nil { firstTimestamp = ts }
                    lastTimestamp = ts
                    if let prev = prevTimestamp {
                        let gap = ts.timeIntervalSince(prev)
                        if gap > 0 && gap <= maxGap { activeTime += gap }
                    }
                    prevTimestamp = ts
                }
                continue
            }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                messageCount += 1
                continue
            }

            let type = json["type"] as? String ?? ""

            // Skip non-message types
            if type == "progress" || type == "queue-operation" || type == "file-history-snapshot" {
                continue
            }

            // Track timestamps
            if let tsStr = json["timestamp"] as? String, let ts = parseDate(tsStr) {
                if firstTimestamp == nil { firstTimestamp = ts }
                lastTimestamp = ts
                if let prev = prevTimestamp {
                    let gap = ts.timeIntervalSince(prev)
                    if gap > 0 && gap <= maxGap { activeTime += gap }
                }
                prevTimestamp = ts
            }

            // Track cwd
            if sessionCwd == nil, let cwd = json["cwd"] as? String {
                sessionCwd = cwd
            }

            guard let message = json["message"] as? [String: Any] else {
                messageCount += 1
                continue
            }

            let content = message["content"]

            switch type {
            case "user":
                messageCount += 1
                let humanText = extractHumanText(from: content)
                if let text = humanText, isGenuineHumanInput(text) {
                    humanMessageCount += 1
                    if genuineHumanMessages.count < maxHumanMessages {
                        genuineHumanMessages.append(String(text.prefix(300)))
                    }
                }

            case "assistant":
                messageCount += 1
                assistantMessageCount += 1

                if let contentArray = content as? [[String: Any]] {
                    // Extract text snippets
                    let textParts = contentArray.compactMap { block -> String? in
                        guard block["type"] as? String == "text",
                              let text = block["text"] as? String else { return nil }
                        return text
                    }
                    let combined = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if combined.count > 50 && isSubstantiveAssistantText(combined) {
                        // Prefer last messages — replace if at capacity
                        if keyAssistantMessages.count < maxAssistantMessages {
                            keyAssistantMessages.append(String(combined.prefix(200)))
                        } else {
                            keyAssistantMessages.removeFirst()
                            keyAssistantMessages.append(String(combined.prefix(200)))
                        }
                    }

                    // Extract tool_use data
                    for block in contentArray {
                        guard block["type"] as? String == "tool_use",
                              let input = block["input"] as? [String: Any] else { continue }

                        // File paths
                        if let fp = input["file_path"] as? String ?? input["path"] as? String {
                            if let short = shortenFilePath(fp) {
                                filesModified.insert(short)
                            }
                        }

                        // Bash commands
                        let toolName = block["name"] as? String ?? ""
                        if toolName.lowercased().contains("bash"),
                           let cmd = input["command"] as? String,
                           commandsRun.count < maxCommands,
                           isInterestingCommand(cmd) {
                            commandsRun.append(String(cmd.prefix(120)))
                        }
                    }
                } else if let textStr = content as? String {
                    let trimmed = textStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 50 && isSubstantiveAssistantText(trimmed) {
                        if keyAssistantMessages.count < maxAssistantMessages {
                            keyAssistantMessages.append(String(trimmed.prefix(200)))
                        } else {
                            keyAssistantMessages.removeFirst()
                            keyAssistantMessages.append(String(trimmed.prefix(200)))
                        }
                    }
                }

            case "summary":
                messageCount += 1
                if let textStr = content as? String {
                    summaryText = String(textStr.prefix(400))
                } else if let arr = content as? [[String: Any]] {
                    for block in arr {
                        if block["type"] as? String == "text", let t = block["text"] as? String {
                            summaryText = String(t.prefix(400))
                            break
                        }
                    }
                }

            default:
                messageCount += 1
            }
        }

        guard messageCount > 1 else { return nil }

        return SessionInfo(
            id: id, projectPath: projectPath, projectName: projectName,
            filePath: filePath, startTime: firstTimestamp, endTime: lastTimestamp,
            messageCount: messageCount, humanMessageCount: humanMessageCount,
            assistantMessageCount: assistantMessageCount,
            genuineHumanMessages: genuineHumanMessages,
            keyAssistantMessages: keyAssistantMessages,
            filesModified: filesModified,
            commandsRun: commandsRun,
            summary: summaryText, cwd: sessionCwd,
            activeDuration: max(activeTime, 0)
        )
    }

    // MARK: - Extract Human Text

    /// Extract plain text from user message content, skipping tool_result arrays
    private func extractHumanText(from content: Any?) -> String? {
        if let textStr = content as? String {
            return textStr
        }
        if let contentArray = content as? [[String: Any]] {
            // If any block is a tool_result, this is not a human-typed message
            let hasToolResult = contentArray.contains { ($0["type"] as? String) == "tool_result" }
            if hasToolResult { return nil }

            let textParts = contentArray.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String else { return nil }
                return text
            }
            let combined = textParts.joined(separator: " ")
            return combined.isEmpty ? nil : combined
        }
        return nil
    }

    // MARK: - Human Input Detection

    private func isGenuineHumanInput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return false }

        // Reject Claude Code UI artifacts
        let rejectPrefixes = [
            "Invoke the ", "Base directory for this skill:",
        ]
        for prefix in rejectPrefixes {
            if trimmed.hasPrefix(prefix) { return false }
        }

        // Reject noise patterns
        let rejectContains = [
            "<command-message>", "<task-notification>", "<system-reminder>",
            "<ide_opened_file>", "<local-command-caveat>",
            "<bash-input>", "<local-command-stdout>", "<local-command-stderr>",
            "<bash-stdout>", "<bash-stderr>",
            "You are a Claude-Mem", "you are a Claude-Mem",
            "specialized observer", "searchable memory",
            "Stop hook feedback", "hook feedback:",
            "You MUST call the StructuredOutput", "StructuredOutput tool",
            "<observed_from_primary_session>", "<what_happened>",
            "<tool_result>", "<function_result>",
            "Analyze this conversation and determine",
            "Context: This summary will be shown",
            "Please write a concise, factual summary",
            "CONTINUE (should_continue:", "STOP (should_continue:",
            "should_continue", "System prompt:", "SYSTEM:",
            "# Commit and Push with PR Creation",
            "This command handles the complete workflo",
            "Run echo ",
        ]
        for pattern in rejectContains {
            if trimmed.contains(pattern) { return false }
        }

        // Reject if just an interruption marker
        if trimmed == "[Request interrupted by user]" { return false }
        // Strip interruption suffix from otherwise valid messages
        // (handled at extraction time — keep the message)

        // Reject high XML/JSON density (system prompt injections)
        let xmlTagCount = trimmed.components(separatedBy: "<").count - 1
        let jsonBraceCount = trimmed.components(separatedBy: "{").count - 1
        let totalSpecial = xmlTagCount + jsonBraceCount
        let wordCount = trimmed.components(separatedBy: .whitespaces).count
        if totalSpecial > 5 && totalSpecial > wordCount / 2 { return false }

        return true
    }

    // MARK: - Assistant Text Filter

    private func isSubstantiveAssistantText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let lowValuePrefixes = [
            "i'll use the", "let me read", "now let me", "let me check",
            "let me look", "i'll read", "i'll check", "let me search",
            "let me explore", "i'll search", "i'll look",
        ]
        for prefix in lowValuePrefixes {
            if lowered.hasPrefix(prefix) { return false }
        }
        return true
    }

    // MARK: - Tool Use Helpers

    private static let sourceExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "swift", "py", "rs", "go", "java", "kt",
        "rb", "ex", "exs", "css", "scss", "html", "vue", "svelte",
        "json", "yaml", "yml", "toml", "sql", "graphql", "prisma",
        "md", "mdx", "sh", "bash", "zsh",
    ]

    /// Shorten an absolute file path to parent/filename for display
    private func shortenFilePath(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let filename = components.last else { return nil }

        // Check extension
        let ext = String(filename.split(separator: ".").last ?? "")
        guard Self.sourceExtensions.contains(ext.lowercased()) else { return nil }

        if components.count >= 2 {
            return "\(components[components.count - 2])/\(filename)"
        }
        return String(filename)
    }

    private static let boringCommands: Set<String> = [
        "ls", "cat", "head", "tail", "echo", "cd", "pwd", "which", "whoami",
        "wc", "stat", "file", "true", "false",
    ]

    private func isInterestingCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = String(trimmed.split(separator: " ").first ?? "")
        let base = String(firstWord.split(separator: "/").last ?? "")
        return !Self.boringCommands.contains(base.lowercased())
    }

    // MARK: - Helpers

    /// Fast timestamp extraction from a raw JSONL line without full JSON parse
    private func extractTimestampCheap(from line: String) -> Date? {
        // Look for "timestamp":"2026-..." pattern
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        let tsStr = String(line[start..<end])
        return parseDate(tsStr)
    }

    private func parseDate(_ string: String) -> Date? {
        if let date = isoFormatter.date(from: string) { return date }
        return isoFormatterNoFrac.date(from: string)
    }

    private func extractProjectName(from encodedPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encodedHome = home.replacingOccurrences(of: "/", with: "-")

        var remainder = encodedPath

        if remainder.hasPrefix(encodedHome) {
            remainder = String(remainder.dropFirst(encodedHome.count))
        }

        while remainder.hasPrefix("-") {
            remainder = String(remainder.dropFirst())
        }

        let commonPrefixes = ["Documents-", "Projects-", "Developer-", "Desktop-",
                              "repos-", "code-", "src-", "workspace-", "Work-",
                              "dev-", "github-", "Git-", "Workspace-",
                              "Crescendolab-", "co-"]

        for prefix in commonPrefixes {
            if let range = remainder.range(of: prefix, options: .caseInsensitive) {
                remainder = String(remainder[range.upperBound...])
                break
            }
        }

        return remainder.isEmpty ? encodedPath : remainder
    }
}
