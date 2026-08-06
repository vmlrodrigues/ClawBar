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

    private var command = "claude setup-token"

    init(onStored: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStored = onStored
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect ClawBar")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("In a terminal, run:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .controlSize(.small).help("Copy")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))

                Text("Then paste the token it prints below. It is stored in your Keychain and sent only to api.anthropic.com.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
