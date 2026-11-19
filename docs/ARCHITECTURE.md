# How Pal is put together

This is a snapshot of the current design. All of it is meant to change. The seams below are where things are designed to be swapped.

| Area | Where | Seam |
| --- | --- | --- |
| Settings | `App/Config.swift` | `PalConfig` is one Codable struct. New fields fall back to their defaults, so adding settings never breaks old saves. |
| Model backends | `Brain/*Backend.swift` | The `Backend` protocol: Claude Code (`claude -p` stream-json), Codex (`app-server`), Claude API (raw SSE). Add a backend by adding a case to `ProviderID` and to `Backends.make`. |
| Quick tier | `Brain/Brain.swift`, `Brain/Prompts.swift` | A fast model handles most requests itself (tools, several steps) and calls `start_agent` only for long or heavy work, passing the request close to the user's words. The card follows handed-off work with short progress lines. |
| Agents | `Brain/SessionManager.swift` | Long-lived backend conversations with history. They resume natively, or from a recap. |
| Tools | `Tools/` | `PalTool` and `ToolRegistry`. Served over MCP from inside the app (`MCPServer` + `Pal --mcp-bridge`), so tools run with Pal's permissions. Add a group, then register it in `Pal.registerTools()`. |
| Schedules | `Schedule/` | Jobs (once, every N minutes, daily, weekdays) that start an agent, wake one, or just notify. |
| Voice | `Voice/` | Mic + SpeechAnalyzer (live text and pauses). Engines: Apple Speech, Apple Dictation, or OpenAI transcription of the finished clip. Speech: Mac voices or OpenAI voices (`OpenAIVoice.swift`). Codex also offers experimental OpenAI realtime voice under a ChatGPT sign-in, which could be another engine later. |
| UI | `UI/` | Dot and card (floating panels), menu bar window, `Settings/` pages. |
| Updates | `System/Updater.swift` | Sparkle; off in dev builds. |

**Builds:**
- *Debug* is **Pal Dev** (`app.pal.mac.dev`, `pal-dev://`, its own state folder).
- *Release* is **Pal** (`app.pal.mac`, hardened runtime, Developer ID).
- The release process is in `scripts/` (see `docs/RELEASING.md`).

**Testing aids** (dev builds use the `pal-dev://` scheme instead of `pal://`):

| Aid | What it does |
| --- | --- |
| `pal://ask?q=…`, `pal://listen`, `pal://settings` | Ask, start listening, or open Settings, from scripts, Raycast or Shortcuts |
| `--args -debugAsk "question"` | Asks once at launch |
| `--args -debugSnapshots <dir>` | Renders Settings and the menu bar window to PNGs |
| `--args -debugAPIBase http://127.0.0.1:8787 -debugAPIKey test` | Points the Claude API backend at a mock |
| `xcodebuild test -scheme Pal` | Unit tests (in `PalTests/`) |
