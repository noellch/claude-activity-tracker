import Foundation

// MARK: - Gemini API Summary Service

class ClaudeSummaryService: ObservableObject {
    @Published var dailySummary: DailySummary?
    @Published var isGenerating = false
    @Published var error: String?
    @Published var historyDates: [Date] = []

    private let summariesDir: String

    private var apiKey: String {
        if let saved = UserDefaults.standard.string(forKey: "gemini_api_key"), !saved.isEmpty {
            return saved
        }
        return ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.summariesDir = "\(home)/.claude-activity/summaries"
        try? FileManager.default.createDirectory(atPath: summariesDir, withIntermediateDirectories: true)
    }

    func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "gemini_api_key")
    }

    // MARK: - Generate Summary

    func generateSummary(from stats: DayStats) {
        guard hasAPIKey else {
            error = "API key not set"
            return
        }

        guard !stats.sessions.isEmpty else {
            dailySummary = DailySummary(
                headline: "No sessions today",
                narrative: "You haven't started any Claude Code sessions today. Take it easy or jump into some coding!",
                highlights: [],
                mood: .quiet
            )
            return
        }

        // Check cache — don't regenerate if sessions haven't changed
        let sessionFingerprint = stats.sessions.map { $0.id }.sorted().joined()
        if let cached = dailySummary, cached.fingerprint == sessionFingerprint {
            return
        }

        // Check disk cache on cold start (app relaunch)
        if dailySummary == nil, let disk = loadSummary(for: Date()), disk.fingerprint == sessionFingerprint {
            dailySummary = disk
            return
        }

        isGenerating = true
        error = nil

        let prompt = buildPrompt(from: stats)

        Task {
            do {
                let summary = try await callGeminiAPI(prompt: prompt)
                let parsed = parseSummaryResponse(summary, fingerprint: sessionFingerprint)

                await MainActor.run {
                    self.dailySummary = parsed
                    self.isGenerating = false
                    self.saveSummary(parsed, for: Date())
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isGenerating = false

                    // Fallback: generate local summary without API
                    let fallback = self.generateLocalSummary(from: stats, fingerprint: sessionFingerprint)
                    self.dailySummary = fallback
                    self.saveSummary(fallback, for: Date())
                }
            }
        }
    }

    // MARK: - Logging

    private func logBackfill(_ message: String) {
        let logPath = "\(summariesDir)/backfill.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    // MARK: - Persistence

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func saveSummary(_ summary: DailySummary, for date: Date) {
        let path = "\(summariesDir)/\(dateKey(date)).json"
        let dict: [String: Any] = [
            "headline": summary.headline,
            "narrative": summary.narrative,
            "highlights": summary.highlights,
            "mood": summary.mood.rawValue,
            "fingerprint": summary.fingerprint,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func loadSummary(for date: Date) -> DailySummary? {
        let path = "\(summariesDir)/\(dateKey(date)).json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let headline = json["headline"] as? String ?? ""
        let narrative = json["narrative"] as? String ?? ""
        let highlights = json["highlights"] as? [String] ?? []
        let moodStr = json["mood"] as? String ?? "productive"
        let mood = DayMood(rawValue: moodStr) ?? .productive
        let fingerprint = json["fingerprint"] as? String ?? ""
        return DailySummary(headline: headline, narrative: narrative, highlights: highlights, mood: mood, fingerprint: fingerprint)
    }

    /// Load list of dates that have saved summaries
    func loadHistoryDates() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: summariesDir) else {
            historyDates = []
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = Calendar.current.startOfDay(for: Date())

        historyDates = files
            .filter { $0.hasSuffix(".json") }
            .compactMap { f.date(from: String($0.dropLast(5))) }
            .filter { $0 < today }
            .sorted(by: >)
    }

    /// Backfill past 7 days that don't have saved summaries
    func backfillHistory(weekStats: [Date: DayStats]) {
        let today = Calendar.current.startOfDay(for: Date())

        // Collect days that need backfill
        var daysToBackfill: [(Date, DayStats)] = []
        for i in 1...6 {
            guard let day = Calendar.current.date(byAdding: .day, value: -i, to: today) else { continue }
            let path = "\(summariesDir)/\(dateKey(day)).json"
            if FileManager.default.fileExists(atPath: path) { continue }
            guard let stats = weekStats[day], stats.totalSessions > 0 else { continue }
            daysToBackfill.append((day, stats))
        }

        guard !daysToBackfill.isEmpty else {
            loadHistoryDates()
            return
        }

        if hasAPIKey {
            // Async backfill via Gemini
            Task {
                // Wait 5s before starting backfill to avoid colliding with today's summary request
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                for (index, (day, stats)) in daysToBackfill.enumerated() {
                    // Rate limit: wait 4s between API calls (Gemini free tier)
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                    let prompt = buildPrompt(from: stats)
                    let fingerprint = "backfill-\(dateKey(day))"

                    // Retry up to 2 times on 429 rate limit
                    var succeeded = false
                    for attempt in 1...3 {
                        do {
                            let response = try await callGeminiAPI(prompt: prompt)
                            let parsed = parseSummaryResponse(response, fingerprint: fingerprint)
                            saveSummary(parsed, for: day)
                            logBackfill("✅ \(dateKey(day)): AI summary saved (attempt \(attempt))")
                            succeeded = true
                            break
                        } catch let err as SummaryError {
                            if case .apiError(let code, _) = err, code == 429, attempt < 3 {
                                logBackfill("⏳ \(dateKey(day)): rate limited, waiting 10s (attempt \(attempt))")
                                try? await Task.sleep(nanoseconds: 10_000_000_000)
                            } else {
                                logBackfill("❌ \(dateKey(day)): \(err.localizedDescription) (attempt \(attempt), prompt: \(prompt.count) chars)")
                                break
                            }
                        } catch {
                            logBackfill("❌ \(dateKey(day)): \(error.localizedDescription) (attempt \(attempt))")
                            break
                        }
                    }

                    if !succeeded {
                        let local = generateLocalSummary(from: stats, fingerprint: fingerprint)
                        saveSummary(local, for: day)
                    }
                }
                await MainActor.run {
                    self.loadHistoryDates()
                }
            }
        } else {
            // Local backfill
            for (day, stats) in daysToBackfill {
                let summary = generateLocalSummary(from: stats, fingerprint: "backfill-\(dateKey(day))")
                saveSummary(summary, for: day)
            }
            loadHistoryDates()
        }
    }

    // MARK: - Build Prompt

    private func buildPrompt(from stats: DayStats) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var sessionDescriptions: [String] = []

        // Cap at 15 sessions to avoid exceeding API token limits
        let sessionsToInclude = stats.sessions.prefix(15)

        for (i, session) in sessionsToInclude.enumerated() {
            let startStr = session.startTime.map { timeFormatter.string(from: $0) } ?? "?"
            let durationStr = session.durationFormatted

            // Skip sessions with no meaningful data
            guard !session.genuineHumanMessages.isEmpty || !session.keyAssistantMessages.isEmpty else { continue }

            var parts: [String] = []
            parts.append("Session \(i + 1) [\(startStr), \(durationStr)] -- Project: \(session.projectName)")

            // Intent: what the user asked
            if !session.genuineHumanMessages.isEmpty {
                parts.append("  Intent:")
                for msg in session.genuineHumanMessages.prefix(3) {
                    parts.append("    - \"\(msg)\"")
                }
            }

            // Files touched
            if !session.filesModified.isEmpty {
                let fileList = session.filesModified.sorted().prefix(10).joined(separator: ", ")
                parts.append("  Files touched: \(fileList)")
            }

            // Commands run
            if !session.commandsRun.isEmpty {
                let cmdList = session.commandsRun.prefix(3).joined(separator: "; ")
                parts.append("  Commands: \(cmdList)")
            }

            // Assistant notes: what Claude said it did
            if !session.keyAssistantMessages.isEmpty {
                parts.append("  Assistant notes:")
                for msg in session.keyAssistantMessages.prefix(3) {
                    parts.append("    - \"\(msg)\"")
                }
            }

            // Summary if available
            if let summary = session.summary {
                parts.append("  Session summary: \(String(summary.prefix(200)))")
            }

            sessionDescriptions.append(parts.joined(separator: "\n"))
        }

        let totalDuration = stats.totalDurationFormatted
        let projectList = stats.projectBreakdown.map { "\($0.key): \($0.value) sessions" }.joined(separator: ", ")

        return """
        You are a concise productivity assistant. Summarize this developer's day working with Claude Code.

        CRITICAL RULES:
        - ONLY describe actual coding work (features built, bugs fixed, refactors, tests written)
        - NEVER mention: system prompts, MCP plugins, hooks, tool configurations, XML tags, StructuredOutput, Claude-Mem, or any meta/infrastructure content
        - The "Intent" lines are what the user actually typed — use these to understand what they wanted
        - The "Files touched" and "Commands" show concrete work done
        - The "Assistant notes" show what Claude reported doing
        - Write in natural, human-readable language as if telling a friend what you accomplished

        STATS:
        - Total sessions: \(stats.totalSessions)
        - Total time: \(totalDuration)
        - Projects: \(projectList)

        SESSIONS:
        \(sessionDescriptions.joined(separator: "\n\n"))

        Respond in this exact JSON format (no markdown, no code fences):
        {
            "headline": "5-8 word headline (e.g. 'Auth refactor & API endpoints')",
            "narrative": "2-3 sentence summary of actual coding work accomplished. Warm and factual.",
            "highlights": ["concrete thing 1", "concrete thing 2", "concrete thing 3"],
            "mood": "productive|focused|exploratory|debugging|creative|quiet"
        }

        Rules:
        - headline = a commit message for the entire day
        - narrative = what you'd tell a colleague you got done
        - highlights = 2-4 specific, concrete accomplishments (max 15 words each)
        - If sessions are in the same project, show the narrative thread
        - Use the user's language if session content is non-English
        """
    }

    // MARK: - Gemini API Call

    private func callGeminiAPI(prompt: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw SummaryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": 500,
                "temperature": 0.7
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummaryError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw SummaryError.parseError
        }

        return text
    }

    // MARK: - Parse Response

    private func parseSummaryResponse(_ response: String, fingerprint: String) -> DailySummary {
        // Clean up response — remove markdown fences if present
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DailySummary(
                headline: "Your day with Claude",
                narrative: response.prefix(300).description,
                highlights: [],
                mood: .productive,
                fingerprint: fingerprint
            )
        }

        let headline = json["headline"] as? String ?? "Your day with Claude"
        let narrative = json["narrative"] as? String ?? ""
        let highlights = json["highlights"] as? [String] ?? []
        let moodStr = json["mood"] as? String ?? "productive"
        let mood = DayMood(rawValue: moodStr) ?? .productive

        return DailySummary(
            headline: headline,
            narrative: narrative,
            highlights: highlights,
            mood: mood,
            fingerprint: fingerprint
        )
    }

    // MARK: - Local Fallback Summary (no API needed)

    func generateLocalSummary(from stats: DayStats, fingerprint: String = "") -> DailySummary {
        let sessionCount = stats.totalSessions
        let projects = stats.projectBreakdown
        let topProject = projects.max(by: { $0.value < $1.value })?.key ?? "your project"
        let projectNames = projects.keys.sorted()

        let headline: String
        let mood: DayMood

        if sessionCount == 0 {
            return DailySummary(
                headline: "No sessions today",
                narrative: "Take it easy or jump into some coding!",
                highlights: [],
                mood: .quiet,
                fingerprint: fingerprint
            )
        } else if sessionCount == 1 {
            headline = "Quick session on \(topProject)"
            mood = .focused
        } else if projects.count == 1 {
            headline = "Focused work on \(topProject)"
            mood = .focused
        } else if sessionCount >= 5 {
            headline = "Busy day across \(projects.count) projects"
            mood = .productive
        } else {
            headline = "Working on \(projectNames.prefix(2).joined(separator: " & "))"
            mood = .exploratory
        }

        let narrative: String
        if projects.count == 1 {
            narrative = "You had \(sessionCount) session\(sessionCount == 1 ? "" : "s") on \(topProject), totaling \(stats.totalDurationFormatted)."
        } else {
            let projectSummary = projects
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key) (\($0.value))" }
                .joined(separator: ", ")
            narrative = "You worked across \(projects.count) projects: \(projectSummary). Total time: \(stats.totalDurationFormatted)."
        }

        // Use genuine human messages as highlights — already pre-cleaned at extraction time
        var highlights: [String] = []
        for session in stats.sessions.prefix(4) {
            if let first = session.genuineHumanMessages.first {
                let truncated = first.count > 80 ? String(first.prefix(77)) + "..." : first
                highlights.append(truncated)
            } else if let first = session.keyAssistantMessages.first {
                let truncated = first.count > 80 ? String(first.prefix(77)) + "..." : first
                highlights.append(truncated)
            }
        }

        return DailySummary(
            headline: headline,
            narrative: narrative,
            highlights: highlights,
            mood: mood,
            fingerprint: fingerprint
        )
    }
}

// MARK: - Models

struct DailySummary {
    let headline: String
    let narrative: String
    let highlights: [String]
    let mood: DayMood
    var fingerprint: String = ""
}

enum DayMood: String {
    case productive
    case focused
    case exploratory
    case debugging
    case creative
    case quiet

    var emoji: String {
        switch self {
        case .productive: return "🚀"
        case .focused: return "🎯"
        case .exploratory: return "🧭"
        case .debugging: return "🔍"
        case .creative: return "✨"
        case .quiet: return "🌙"
        }
    }

    var label: String {
        rawValue.capitalized
    }

    var color: String {
        switch self {
        case .productive: return "D97706"
        case .focused: return "2563EB"
        case .exploratory: return "7C3AED"
        case .debugging: return "DC2626"
        case .creative: return "059669"
        case .quiet: return "6B7280"
        }
    }
}

enum SummaryError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .apiError(let code, let msg):
            return "API error (\(code)): \(msg.prefix(100))"
        case .parseError:
            return "Failed to parse API response"
        }
    }
}
