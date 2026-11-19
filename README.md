# Pal

A voice companion for macOS that's also a full agent. A small dot sits in the corner of your screen. Ask it quick things and it answers on a glass card. Hand it bigger jobs and it runs background agents that work your Mac and report back.

## Using it

| How | What happens |
| --- | --- |
| **Hold Right Option**, talk, let go | Sends when you let go |
| **⌥ Space**, talk, pause | Sends after a short pause (or press again) |
| **Click the dot** | Same as ⌥ Space |
| **Menu bar icon** | Pal's window: chat (type or talk), agents, scheduled |
| **Right-click the dot or icon** | Quick actions: ask, agents, speak replies, settings |
| **Esc** | Stops listening/thinking/speaking and hides the card |
| `pal://ask?q=…` | Ask from Raycast, Shortcuts or scripts (also `pal://listen`, `pal://settings`) |

The card has **read aloud** and **copy** buttons. Agent updates also have **Open**. Spoken replies are off by default (Settings › Voice).

The dot's states: idle, listening (grows with your voice), thinking (orbit), speaking (ripples), agents working (slow ring), needs you (pulse). Colors, size, corner and display are in Settings › Appearance.

## How it works

```
voice/typing ─▶ quick tier (fast model) ──answers──▶ card + voice
                        │
                        ├─ small Mac tasks itself (timers, reminders, calendar, apps…)
                        └─ start_agent ─▶ agent sessions (capable model, full access)
                                              │  shell, files, web, your MCPs + skills,
                                              │  computer use, browser, wake-ups
                                              └─ report back ─▶ card / notification / chat
```

- **Quick tier**: Claude Sonnet (low effort) or GPT-6.1-Terra. It answers directly, uses Pal's tools for small things, and hands bigger work to agents. It can pick a model when you ask for one ("use Astra").
- **Agents**: Claude Opus (medium effort) or GPT-6.2-Sol, running in your Claude Code or Codex with your own MCP servers, skills and settings, plus Pal's tools. They work in `~/Pal/workspace`. With full access on (the default), they don't stop to ask for each command.
- **Pal's tools** are served over MCP from inside the Pal app, so they run with the permissions you gave Pal:
  - Reminders, Calendar, Contacts
  - Timers, alarms and world clock
  - Apps, Shortcuts, AppleScript, volume, media, dark mode and clipboard
  - **Computer use**: accessibility tree, screenshots, click and type
  - Memory and skills
  - Agents, schedules and wake-ups
- **Browser**: [OpenCode Browse](https://opencode.ai/product/browse) (works in your own signed-in Chrome) or Playwright.
- **Schedules**: one-off, every N minutes, daily or weekdays. A schedule can start an agent, wake an existing one, or just remind you. Agents monitor things by calling `wake_me_in` instead of busy-waiting.
- **Memory**: markdown files in `~/Pal/memory`. Pal saves lasting facts on its own (you can turn this off).
- **Skills**: `~/Pal/skills/<name>/SKILL.md`. Claude agents also find them natively.

AI comes from what you're already signed in to: Claude Code, or Codex with ChatGPT. No Claude Code or Codex? Add a Claude API key in Settings › Models. It's kept in the Keychain, and Pal then runs the agent loop itself over the Messages API, using its own tools plus shell and file tools for agents and Anthropic's hosted web search.

Agents that went quiet release their process after an hour. Messaging one later reopens the real Claude Code session or Codex thread, so it remembers everything. If that fails, it continues from a summary.

## Settings

The sidebar has: General, Appearance, Voice (speech-to-text engine and language, voice, speed), Models (accounts, quick/agent model and effort per provider), Agents (access, concurrency, workspace, browser, your MCP servers), Tools (toggle each tool), Permissions (check and allow each one), Memory, Skills and Schedules.

## Build

Requires macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./scripts/run.sh
```

This generates `Pal.xcodeproj`, builds into `build/`, and relaunches the app.

It signs ad-hoc ("Sign to Run Locally") by default, so macOS may ask for permissions again after rebuilds. For a stable signature, create `Config/Local.xcconfig` (it's git-ignored):

```
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <your team id>
```

Testing aids:
- `open Pal.app --args -debugAsk "question"` asks once at launch.
- `open "pal://ask?q=..."` asks while Pal is running.
- `--args -debugSnapshots /tmp/snaps` renders Settings and the menu bar window to PNGs.
- `--args -debugAPIBase http://127.0.0.1:8787 -debugAPIKey test` points the Claude API backend at a local mock.

## Layout

```
Pal/App        entry, Pal (controller), config, paths, view model
Pal/Brain      backends (Claude Code, Codex app-server), quick tier, agent sessions, prompts, accounts
Pal/Tools      tool registry, MCP server + stdio bridge, tool groups, memory & skills
Pal/Schedule   scheduler, timers
Pal/System     permissions, notifications
Pal/Voice      mic + on-device speech, text-to-speech, hotkeys
Pal/UI         dot, card, panels, menu bar window, Settings/
```

Adding a tool: write a `PalTool` in a group under `Pal/Tools` and register it in `Pal.registerTools()`. It shows up in Settings › Tools and for both tiers automatically.
