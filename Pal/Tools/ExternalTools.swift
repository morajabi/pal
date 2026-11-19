import Foundation

/// Third-party MCP servers Pal can hand to its agents (on top of whatever the user set up
/// in Claude Code / Codex themselves, which agents load automatically).
enum ExternalTools {
    struct Server {
        var name: String
        var spec: MCPServerSpec
    }

    @MainActor
    static func browserServer(accounts: Accounts) -> Server? {
        switch PalSettings.c.browserTool {
        case .opencodeBrowse:
            // OpenCode Browse works in the user's own Chrome through its extension.
            if let path = accounts.browsePath {
                return Server(name: "browse", spec: MCPServerSpec(command: path, args: ["mcp"]))
            }
            return nil
        case .playwright:
            if let npx = accounts.npxPath {
                return Server(name: "playwright", spec: MCPServerSpec(command: npx, args: ["-y", "@playwright/mcp@latest"]))
            }
            return nil
        case .off:
            return nil
        }
    }

    static let browseInstallURL = URL(string: "https://opencode.ai/product/browse")!
}
