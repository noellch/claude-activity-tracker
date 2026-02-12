# ✦ Claude Activity Tracker

A macOS menu bar app that shows what you accomplished with Claude today.

Instead of just tracking "how much time you spent with AI," this tool focuses on **what you got done** — reading your Claude Code session data to surface a daily activity dashboard right in your menu bar.

## How It Works

```
~/.claude/projects/
├── -Users-you-project-a/
│   ├── session-uuid-1.jsonl    ← parsed for messages, timestamps, summaries
│   └── session-uuid-2.jsonl
├── -Users-you-project-b/
│   └── session-uuid-3.jsonl
```

Claude Code stores every conversation as JSONL files. This app reads them and shows:

- **Today's sessions** — how many, which projects, what was discussed
- **Time tracking** — duration of each session based on first/last message timestamps
- **Summaries** — what was accomplished in each session (from system summaries)
- **Weekly overview** — bar chart of your 7-day activity pattern
- **Project breakdown** — which projects got the most attention

## Architecture

```
ClaudeActivityTracker/
├── ClaudeActivityTrackerApp.swift   # App entry, NSStatusItem, popover
├── ClaudeActivityMonitor.swift      # JSONL parser, session data model
├── DashboardView.swift              # SwiftUI popover UI
└── Package.swift                    # Swift Package Manager config
```

### Key Design Decisions

- **Swift + SwiftUI** — native macOS, minimal resource usage (~10MB RAM)
- **No network requests** — reads local files only, fully offline
- **60s refresh interval** — light on CPU, always up to date
- **Lazy parsing** — only parses first/last lines of large JSONL files for performance
- **No privacy concerns** — data never leaves your machine

## Build & Run

### Prerequisites
- macOS 13+ (Ventura)
- Xcode 15+ or Swift 5.9+

### Option 1: Xcode
1. Open the project folder in Xcode
2. Build & Run (⌘R)

### Option 2: Command Line
```bash
cd claude-activity-tracker
swift build -c release
# Binary at .build/release/ClaudeActivityTracker
```

### Launch at Login
1. Open **System Settings → General → Login Items**
2. Add the built app

## Roadmap

- [x] Read Claude Code JSONL sessions
- [ ] Claude.ai web session tracking (via browser extension)
- [ ] AI-powered daily summary (call Claude API to summarize your day)
- [ ] Keyboard shortcut to open dashboard
- [ ] Export weekly report as markdown
- [ ] Notification: "You've been coding with Claude for 2 hours — take a break?"
- [ ] Token usage tracking (estimate API costs)
- [ ] Integration with other productivity tools (Raycast, Alfred)

## Data Format

Each JSONL line in a session file follows this structure:

```json
{"type":"user","message":{"role":"user","content":"Help me fix the auth bug"},"timestamp":"2025-02-11T10:30:00.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll help..."}]},"timestamp":"2025-02-11T10:30:15.000Z"}
{"type":"summary","message":{"role":"user","content":"Fixed auth bug by..."},"timestamp":"2025-02-11T11:00:00.000Z"}
```

The app parses `type`, `timestamp`, and content preview from these lines.

## License

MIT
