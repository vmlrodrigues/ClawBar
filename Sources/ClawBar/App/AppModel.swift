import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var isRefreshing = false

    /// Fired whenever anything the status item renders may have changed.
    var onChange: (() -> Void)?

    let notifier = Notifier()
    private let log = UsageLog()
    private let projectionHistory = ProjectionHistory()

    /// Where the weekly window is heading, or nil while there is too little history.
    var weeklyProjection: Projection? {
        guard let weekly = snapshot?.weekly else { return nil }
        return projectionHistory.projection(for: weekly)
    }

    var hasToken: Bool { TokenStore.read() != nil }

    /// Drives the polling floor near a limit.
    var worstPercent: Int {
        max(snapshot?.session?.percent ?? 0, snapshot?.weekly?.percent ?? 0)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard hasToken else {
            state = .noToken
            onChange?()
            return
        }

        isRefreshing = true
        onChange?()
        defer {
            isRefreshing = false
            onChange?()
        }

        do {
            let fresh = try await AnthropicUsageClient.fetch()
            snapshot = fresh
            state = .ok
            // Recorded unconditionally: the projection must not depend on the usage log,
            // which is an optional diagnostic.
            projectionHistory.record(fresh)
            if Preferences.shared.writeUsageLog { log?.record(fresh) }
            notifier.evaluate(fresh)
        } catch let error as FetchError {
            switch error.kind {
            case .noToken:
                state = .noToken
            case .auth:
                state = .needsAuth
            case .limited:
                // A 429 carries no rate-limit headers at all, so the cached snapshot —
                // including its reset timestamp — is the only thing keeping the
                // countdown alive. Never clear it here.
                state = snapshot == nil ? .failed(error.message) : .limited
            case .other:
                state = snapshot == nil ? .failed(error.message) : .stale(error.message)
            }
        } catch {
            state = snapshot == nil
                ? .failed(error.localizedDescription)
                : .stale(error.localizedDescription)
        }
    }

    /// Called after onboarding stores a token, to leave the error state immediately.
    func tokenChanged() async {
        state = .loading
        onChange?()
        await refresh()
    }
}
