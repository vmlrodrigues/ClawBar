import Foundation

/// Detects the Claude Code CLI, which ClawBar needs for exactly one thing: minting a
/// token with `claude setup-token`. There is no other documented way to get one — a
/// Console API key authenticates differently and reports API rate limits against billed
/// credits, not the subscription's session and weekly windows.
///
/// Claude Desktop does **not** bundle the CLI, so someone who only uses Claude for chat
/// and Cowork has to install it even though they will never otherwise run it. Saying so
/// plainly beats letting them discover it at a dead end.
enum ClaudeCode {
    /// PATH is near-useless from a GUI app — it inherits launchd's, not the shell's — so
    /// the known install locations are probed directly.
    private static let candidates = [
        "/opt/homebrew/bin/claude",                                   // Homebrew, Apple silicon
        "/usr/local/bin/claude",                                      // Homebrew, Intel; npm prefix
        NSHomeDirectory() + "/.local/bin/claude",                     // official installer
        NSHomeDirectory() + "/.claude/local/claude",                  // local install
        NSHomeDirectory() + "/.bun/bin/claude",
    ]

    static var installedPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `CLAWBAR_FAKE_NO_CLAUDE=1` forces the not-installed branch. The onboarding written
    /// for that case is otherwise unreachable on any machine that has Claude Code — which
    /// is every machine this gets developed on.
    static var isInstalled: Bool {
        if ProcessInfo.processInfo.environment["CLAWBAR_FAKE_NO_CLAUDE"] == "1" { return false }
        return installedPath != nil
    }

    /// Whether Claude Code has ever run here. Distinct from `isInstalled`: this is what
    /// the activity monitor watches, so its absence means ClawBar has no way to tell
    /// when you are working and must fall back to the timed refresh.
    static var hasRunBefore: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude")
    }

    /// The install command that suits this machine, or nil if neither package manager is
    /// present — in which case there is nothing honest to suggest running.
    static var suggestedInstallCommand: String? {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew") {
            return "brew install --cask claude-code"
        }
        for npm in ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        where FileManager.default.isExecutableFile(atPath: npm) {
            return "npm install -g @anthropic-ai/claude-code"
        }
        return nil
    }
}
