# Claude Activity Tracker

A macOS menu bar app that reads Claude Code JSONL session files and displays daily activity summaries powered by Gemini AI.

## Features

- **AI Daily Summary** — Gemini Flash generates a headline, narrative, and highlights from your sessions
- **Active Time Tracking** — gap-based duration (ignores idle time > 30 min)
- **History** — persistent daily summaries with 7-day backfill via Gemini API
- **Project Time Chart** — horizontal bar chart showing time per project this week
- **Auto-Refresh** — file watcher detects JSONL changes, no manual refresh needed
- **Session Caching** — skips re-parsing unchanged files based on modification date

## How It Works

```
~/.claude/projects/**/*.jsonl
        | loadAllSessions() + cache
    [SessionInfo] x N
        | group by day
    DayStats (today) + weekStats (7 days)
        | buildPrompt()
    Gemini API
        | parseSummaryResponse()
    DailySummary -> UI + disk cache
```

Claude Code stores every conversation as JSONL files in `~/.claude/projects/`. This app parses them to extract:

- **Intent** — genuine human messages (filtered from tool_results, system prompts, plugin noise)
- **Files touched** — from tool_use file_path inputs
- **Commands run** — from bash tool_use inputs
- **Assistant notes** — substantive Claude responses

## Architecture

```
ClaudeActivityTracker/
  ClaudeActivityTrackerApp.swift   # App entry, NSStatusItem, popover, file watcher setup
  ClaudeActivityMonitor.swift      # JSONL parser, session data model, file watcher, caching
  ClaudeSummaryService.swift       # Gemini API, prompt builder, persistence, backfill
  DashboardView.swift              # SwiftUI UI (Today / This Week / History tabs)
```

## Build & Run

Requires macOS 13+ and Swift 5.9+.

```bash
swift build -c release
.build/release/ClaudeActivityTracker
```

## Configuration

Click the gear icon in the app popover to open Settings:

- **Gemini API Key** — get a free key from [Google AI Studio](https://aistudio.google.com/apikey). Without it, summaries use local fallback (no AI).
- Also reads from environment variable `GEMINI_API_KEY`.

Summaries are saved to `~/.claude-activity/summaries/YYYY-MM-DD.json`.

## License

MIT
