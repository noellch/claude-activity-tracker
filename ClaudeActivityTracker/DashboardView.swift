import SwiftUI

// MARK: - Main Dashboard View

struct DashboardView: View {
    @ObservedObject var monitor: ClaudeActivityMonitor
    @StateObject private var summaryService = ClaudeSummaryService()
    @State private var selectedTab: DashboardTab = .today
    @State private var showSettings = false

    enum DashboardTab {
        case today, week, history
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            tabSelector

            ScrollView {
                switch selectedTab {
                case .today:
                    todayView
                case .week:
                    weekView
                case .history:
                    historyView
                }
            }

            Divider()
            footerView
        }
        .frame(width: 380, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            SettingsView(summaryService: summaryService)
        }
        .onChange(of: monitor.todayStats.totalSessions) { _ in
            triggerSummary()
            summaryService.backfillHistory(weekStats: monitor.weekStats)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                triggerSummary()
            }
        }
    }

    private func triggerSummary() {
        if summaryService.hasAPIKey {
            summaryService.generateSummary(from: monitor.todayStats)
        } else {
            let summary = summaryService.generateLocalSummary(from: monitor.todayStats)
            summaryService.dailySummary = summary
            summaryService.saveSummary(summary, for: Date())
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "D97706"), Color(hex: "EA580C")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Activity")
                    .font(.system(size: 14, weight: .semibold))
                Text(dateString(Date()))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if monitor.todayStats.totalSessions > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(monitor.todayStats.totalSessions) sessions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tabs

    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton("Today", tab: .today)
            tabButton("This Week", tab: .week)
            tabButton("History", tab: .history)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ title: String, tab: DashboardTab) -> some View {
        Button(action: { selectedTab = tab }) {
            Text(title)
                .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    selectedTab == tab
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Today View

    private var todayView: some View {
        VStack(spacing: 14) {
            statsCardsView
            aiSummaryView

            if !monitor.todayStats.projectBreakdown.isEmpty {
                projectBreakdownView
            }
        }
        .padding(16)
    }

    // MARK: - AI Summary Card (hero)

    private var aiSummaryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if summaryService.isGenerating {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Generating daily summary...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            } else if let summary = summaryService.dailySummary {
                VStack(alignment: .leading, spacing: 10) {
                    // Mood + headline
                    HStack(spacing: 8) {
                        Text(summary.mood.emoji)
                            .font(.system(size: 20))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.headline)
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(2)

                            Text(summary.mood.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(hex: summary.mood.color))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: summary.mood.color).opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    // Narrative
                    Text(summary.narrative)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // Highlights
                    if !summary.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summary.highlights, id: \.self) { highlight in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("✦")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color(hex: "D97706"))
                                        .padding(.top, 2)

                                    Text(highlight)
                                        .font(.system(size: 11))
                                        .foregroundColor(.primary.opacity(0.8))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }

                    // Actions row
                    HStack {
                        if !summaryService.hasAPIKey {
                            Button(action: { showSettings = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9))
                                    Text("Add Gemini key for AI summaries")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(Color(hex: "D97706"))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: {
                                summaryService.dailySummary = nil
                                summaryService.generateSummary(from: monitor.todayStats)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 9))
                                    Text("Regenerate")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        if summaryService.hasAPIKey {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9))
                                Text("AI")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(Color(hex: "D97706").opacity(0.5))
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color(hex: "D97706").opacity(0.3),
                                            Color(hex: "EA580C").opacity(0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )

            } else if monitor.todayStats.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No Claude sessions today")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Start a Claude Code session to see your activity here.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }

            if let error = summaryService.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Stats Cards

    private var statsCardsView: some View {
        HStack(spacing: 10) {
            StatCard(icon: "bubble.left.and.bubble.right", title: "Sessions",
                     value: "\(monitor.todayStats.totalSessions)", color: Color(hex: "D97706"))
            StatCard(icon: "clock", title: "Time",
                     value: monitor.todayStats.totalDurationFormatted, color: Color(hex: "2563EB"))
            StatCard(icon: "text.bubble", title: "Messages",
                     value: "\(monitor.todayStats.totalHumanMessages)", color: Color(hex: "7C3AED"))
        }
    }

    // MARK: - Project Breakdown

    private var projectBreakdownView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(
                monitor.todayStats.projectBreakdown.sorted(by: { $0.value > $1.value }),
                id: \.key
            ) { project, count in
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "D97706"))
                    Text(project)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Week View

    private var weekView: some View {
        VStack(spacing: 16) {
            weekChartView
            weekProjectTimeView
            weekListView
        }
        .padding(16)
    }

    private var weekChartView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    let day = Calendar.current.date(byAdding: .day, value: -(6 - i), to: Calendar.current.startOfDay(for: Date()))!
                    let stats = monitor.weekStats[day]
                    let count = stats?.totalSessions ?? 0
                    let maxCount = monitor.weekStats.values.map(\.totalSessions).max() ?? 1

                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == 6 ? Color(hex: "D97706") : Color(hex: "D97706").opacity(0.4))
                            .frame(height: max(4, CGFloat(count) / CGFloat(max(maxCount, 1)) * 60))

                        Text(shortDayName(day))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(i == 6 ? .primary : .secondary)
                    }
                }
            }
            .frame(height: 80)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var weekProjectTimeView: some View {
        let projectDurations = computeWeekProjectDurations()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Time by Project")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if projectDurations.isEmpty {
                Text("No project data this week")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
            } else {
                let maxDuration = projectDurations.first?.duration ?? 1

                ForEach(projectDurations, id: \.project) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.project)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(formatDuration(item.duration))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "D97706").opacity(0.7))
                                .frame(width: max(4, geo.size.width * CGFloat(item.duration / maxDuration)))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private struct ProjectDuration: Hashable {
        let project: String
        let duration: TimeInterval
    }

    private func computeWeekProjectDurations() -> [ProjectDuration] {
        var projectTime: [String: TimeInterval] = [:]
        for (_, dayStats) in monitor.weekStats {
            for session in dayStats.sessions {
                projectTime[session.projectName, default: 0] += session.duration
            }
        }
        return projectTime
            .map { ProjectDuration(project: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval / 60)
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private var weekListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = Calendar.current.date(byAdding: .day, value: -i, to: Calendar.current.startOfDay(for: Date()))!
                let stats = monitor.weekStats[day]

                HStack {
                    Text(i == 0 ? "Today" : relativeDayName(day))
                        .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                        .frame(width: 80, alignment: .leading)
                    Text("\(stats?.totalSessions ?? 0) sessions")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(stats?.totalDurationFormatted ?? "0 min")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                if i < 6 { Divider() }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - History View

    private var historyView: some View {
        VStack(spacing: 14) {
            if summaryService.historyDates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No history yet")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Summaries are saved automatically each day. Check back tomorrow.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(summaryService.historyDates, id: \.self) { date in
                    if let summary = summaryService.loadSummary(for: date) {
                        historySummaryCard(date: date, summary: summary)
                    }
                }
            }
        }
        .padding(16)
        .onAppear {
            summaryService.backfillHistory(weekStats: monitor.weekStats)
        }
    }

    private func historySummaryCard(date: Date, summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date header
            HStack {
                Text(relativeDayName(date))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(summary.mood.emoji)
                    .font(.system(size: 14))
            }

            // Headline
            Text(summary.headline)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)

            // Narrative
            Text(summary.narrative)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Highlights
            if !summary.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.highlights.prefix(3), id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 5) {
                            Text("✦")
                                .font(.system(size: 8))
                                .foregroundColor(Color(hex: "D97706"))
                                .padding(.top, 2)
                            Text(highlight)
                                .font(.system(size: 10))
                                .foregroundColor(.primary.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if let lastRefresh = monitor.lastRefresh {
                Text("Updated \(timeAgo(lastRefresh))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                monitor.refresh()
                triggerSummary()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    private func shortDayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func relativeDayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

// MARK: - Subviews

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var summaryService: ClaudeSummaryService
    @State private var apiKeyInput: String = ""
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(hex: "D97706"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Gemini API Key")
                    .font(.system(size: 12, weight: .semibold))

                Text("Used to generate AI-powered daily summaries. Your key is stored locally and never shared.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)

                HStack(spacing: 8) {
                    SecureField("AIza...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button(action: {
                        summaryService.setAPIKey(apiKeyInput)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                    }) {
                        Text(saved ? "✓ Saved" : "Save")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(saved ? .green : Color(hex: "D97706"))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("Or set the GEMINI_API_KEY environment variable.")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary.opacity(0.7))

                if summaryService.hasAPIKey {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("API key configured")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Without an API key")
                    .font(.system(size: 12, weight: .semibold))
                Text("Basic summaries are generated locally from session metadata. With an API key, Gemini creates natural, insightful daily narratives.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 340)
        .onAppear {
            apiKeyInput = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
