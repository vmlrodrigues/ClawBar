import SwiftUI

/// First-run token entry.
///
/// Note the Cmd+V trap this window sits on top of: an `LSUIElement` app has no main
/// menu, and without an Edit menu the standard editing commands never reach the
/// responder chain — so paste would not work in the one field that exists to receive a
/// pasted token. `AppDelegate` installs a minimal Edit menu to fix that.
struct OnboardingView: View {
    var onStored: () -> Void
    var onCancel: () -> Void

    @State private var token = ""
    @State private var checking = false
    @State private var error: String?
    @State private var claudeCodeInstalled = ClaudeCode.isInstalled

    private let command = "claude setup-token"

    init(onStored: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStored = onStored
        self.onCancel = onCancel
    }

    /// A copyable command in a box, with the copy button. Used for both the install
    /// command and the token command.
    private func commandBox(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .controlSize(.small).help("Copy")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect ClawBar")
                .font(.system(size: 15, weight: .semibold))

            // Claude Desktop does not bundle the CLI, so someone who only uses Claude for
            // chat and Cowork hits this and has no idea why a menu bar app wants a
            // terminal. Saying it outright beats letting them find out at a dead end.
            if !claudeCodeInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Claude Code is not installed", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("""
                         ClawBar needs it for one thing only: minting a token. There is no \
                         other way to get one. You never have to use Claude Code \
                         afterwards — a token lasts about a year.
                         """)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let install = ClaudeCode.suggestedInstallCommand {
                        commandBox(install)
                    } else {
                        Text("Install Claude Code first — Homebrew and npm are the usual routes.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("Check again") { claudeCodeInstalled = ClaudeCode.isInstalled }
                        .controlSize(.small)
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("In a terminal, run:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                commandBox(command)

                Text("Then paste the token it prints below. It is stored in your Keychain and sent only to api.anthropic.com.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(claudeCodeInstalled ? 1 : 0.45)
            .disabled(!claudeCodeInstalled)

            SecureField("sk-ant-…", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { store() }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("A setup token lasts about a year. ClawBar checks usage with one tiny request; it never reads your conversations.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if checking {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Connect") { store() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func store() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !checking else { return }
        guard TokenStore.looksPlausible(trimmed) else {
            error = "That does not look like a token — they start with sk-ant-."
            return
        }
        checking = true
        error = nil
        Task {
            // Verify before storing, so a bad paste fails here rather than silently
            // leaving the bar in an error state.
            let result = await AnthropicUsageClient.validate(token: trimmed)
            checking = false
            switch result {
            case .success:
                if TokenStore.write(trimmed) {
                    token = ""
                    onStored()
                } else {
                    error = "Could not write to the Keychain."
                }
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}
