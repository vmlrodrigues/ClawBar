import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let updater = UpdaterController()
    private var statusItem: StatusItemController!
    private var scheduler: PollScheduler!
    private var activityMonitor: ActivityMonitor?
    private var popover: NSPopover?
    private var pendingPopoverTeardown: DispatchWorkItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var displayTimer: DispatchSourceTimer?
    private var debugSignalSource: DispatchSourceSignal?
    private var debugCycleSource: DispatchSourceSignal?
    private var debugSettingsSource: DispatchSourceSignal?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        statusItem = StatusItemController(model: model)
        statusItem.onClick = { [weak self] in self?.togglePopover() }

        scheduler = PollScheduler { [weak self] in await self?.model.refresh() }
        scheduler.worstPercent = { [weak self] in self?.model.worstPercent ?? 0 }

        activityMonitor = ActivityMonitor { [weak self] in
            Task { @MainActor in self?.scheduler.reschedule() }
        }
        scheduler.idleFor = { [weak self] in self?.activityMonitor?.idleFor ?? .infinity }

        model.onChange = { [weak self] in self?.statusItem.update() }

        // Preference changes must repaint the bar (mode/format) and can change the poll
        // cadence (idle behaviour). objectWillChange fires *before* the value updates,
        // so hop a runloop pass to read the new one.
        Preferences.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.statusItem.update()
                self?.scheduler.reschedule()
                self?.applyHotKey()
            }
            .store(in: &cancellables)

        HotKeyCenter.shared.onTrigger = { Preferences.shared.cycleBarMode() }
        applyHotKey()

        registerSleepWake()
        registerAppearanceChanges()
        startDisplayTicker()
        installDebugSignalHandler()
        model.notifier.requestAuthorization()
        statusItem.update()

        if model.hasToken {
            Task {
                await model.refresh()
                scheduler.reschedule()
            }
        } else {
            showOnboarding()
        }
    }

    // MARK: - Menu

    /// An LSUIElement app has no main menu, and without an Edit menu the standard
    /// editing commands never reach the responder chain — so Cmd+V would not work in the
    /// one field that exists to receive a pasted token.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ClawBar",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    // MARK: - Popover

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        pendingPopoverTeardown?.cancel()
        pendingPopoverTeardown = nil

        // Reused while warm. Rebuilding per open fixed the detached-popover bug but cost
        // a fresh SwiftUI view graph each time — six quick opens peaked at 238 MB. The
        // actual cause of the detachment was a *stale* content size, so re-measuring
        // immediately before each show fixes it without the churn.
        let popover = self.popover ?? makePopover()
        self.popover = popover
        if let hosting = popover.contentViewController {
            hosting.view.layoutSubtreeIfNeeded()
            let fitting = hosting.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { popover.contentSize = fitting }
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await model.refresh() }   // always fresh on open
    }

    private func makePopover() -> NSPopover {
        let view = PopoverView(
            model: model,
            openSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showSettings()
            },
            openOnboarding: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showOnboarding()
            }
        )
        let hosting = NSHostingController(rootView: view)
        // Keeps preferredContentSize in step with SwiftUI's ideal size. Without it the
        // popover sizes itself from whatever the hosting controller last reported.
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.layoutSubtreeIfNeeded()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        return popover
    }

    // MARK: - Windows

    private func showOnboarding() {
        if let existing = onboardingWindow {
            raise(existing)
            return
        }
        let view = OnboardingView(
            onStored: { [weak self] in
                self?.closeOnboarding()
                Task { @MainActor in
                    await self?.model.tokenChanged()
                    self?.scheduler.reschedule()
                }
            },
            onCancel: { [weak self] in self?.closeOnboarding() }
        )
        onboardingWindow = presentWindow(title: "Connect ClawBar",
                                         content: NSHostingController(rootView: view))
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func showSettings() {
        if let existing = settingsWindow {
            raise(existing)
            return
        }
        let view = SettingsView(updater: updater, onReplaceToken: { [weak self] in
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
            self?.showOnboarding()
        })
        settingsWindow = presentWindow(title: "ClawBar Settings",
                                       content: NSHostingController(rootView: view))
    }

    private func presentWindow(title: String, content: NSViewController) -> NSWindow {
        // Force SwiftUI to lay out and adopt its real size *before* the window is
        // positioned. Centring against a not-yet-laid-out frame is what left the setup
        // dialog parked at an arbitrary height.
        content.view.layoutSubtreeIfNeeded()
        let fitting = content.view.fittingSize

        let window = NSWindow(contentViewController: content)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if fitting.width > 0, fitting.height > 0 {
            window.setContentSize(fitting)
        }

        // A menu bar app cannot reliably raise its own windows.
        // `NSApp.activate(ignoringOtherApps:)` is deprecated on macOS 14+ and was
        // observed leaving this window at rank 4 in the z-order — mapped, on screen,
        // and completely invisible behind other applications. Floating level plus
        // orderFrontRegardless is what actually brings it to the user.
        // Floating *only until it has been seen*, then demoted to normal in
        // `windowDidBecomeKey`.
        //
        // Permanently floating was a real bug: Settings then outranked Sparkle's update
        // dialog, which uses the normal level, so the dialog was unreachable and the
        // update could not be installed. But plain normal is not the answer either —
        // macOS refuses focus-stealing to background apps, so an accessory app's window
        // can open behind everything and never be noticed.
        //
        // This gets both. If activation succeeds the window becomes key immediately and
        // drops to normal, outranking nothing. If macOS denies activation, it never
        // becomes key and stays floating — which is exactly the case where floating is
        // the only thing making it visible.
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.hidesOnDeactivate = false
        // Without this, closing via the red button leaves the window (and its whole
        // SwiftUI view graph) resident forever, because isReleasedWhenClosed is false
        // and we hold a strong reference.
        window.delegate = self

        raise(window)
        return window
    }

    /// Centre on the screen the menu bar item lives on, and force to the front.
    ///
    /// `NSWindow.center()` put the window hard against the top of the screen, and
    /// `NSScreen.main` is unreliable for an accessory app with no key window — it can
    /// name a different display entirely. The status item's own window is the
    /// authoritative answer to "which screen is the user looking at".
    private func raise(_ window: NSWindow) {
        let screen = statusItem?.button?.window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
        } else {
            window.center()
        }

        NSApp.activate()                  // macOS 14+ replacement for the deprecated call
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Lifecycle

    private func registerSleepWake() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.suspend() }
        }
        centre.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduler.resume()
                Task { await self.model.refresh() }
            }
        }
    }

    /// The glyph colours are baked into cached images at draw time, so a light/dark
    /// switch has to drop them — otherwise the menu bar keeps its old-theme colour.
    private func registerAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                SymbolCache.invalidate()
                self?.statusItem.forceRedraw()
            }
        }
    }

    /// Re-registers the global hotkey from current preferences. Cheap enough to call on
    /// every preference change — unregister/register is a couple of Carbon calls.
    private func applyHotKey() {
        let prefs = Preferences.shared
        guard prefs.hotKeyEnabled else {
            HotKeyCenter.shared.unregister()
            return
        }
        HotKeyCenter.shared.register(keyCode: prefs.hotKeyCode,
                                     carbonModifiers: prefs.hotKeyModifiers)
    }

    /// `kill -USR1 <pid>` toggles the popover, so its geometry can be verified without
    /// Accessibility permissions. Inert unless CLAWBAR_DEBUG=1 is set in the
    /// environment, so it costs nothing in normal use.
    private func installDebugSignalHandler() {
        guard ProcessInfo.processInfo.environment["CLAWBAR_DEBUG"] == "1" else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        source.resume()
        debugSignalSource = source

        // SIGUSR2 fires the same action the global hotkey does, so the cycle can be
        // exercised without synthesising key events.
        signal(SIGUSR2, SIG_IGN)
        let cycle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        cycle.setEventHandler {
            MainActor.assumeIsolated {
                Preferences.shared.cycleBarMode()
                FileHandle.standardError.write(Data(
                    "ClawBar: barMode -> \(Preferences.shared.barMode.rawValue)\n".utf8))
            }
        }
        cycle.resume()
        debugCycleSource = cycle

        // SIGINFO opens Settings, so the window can be inspected without clicking.
        signal(SIGINFO, SIG_IGN)
        let settings = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        settings.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        settings.resume()
        debugSettingsSource = settings
    }

    /// Ticks the countdown between polls. No network; `update()` is change-gated, so
    /// this costs one attributed-string assignment per minute at most.
    private func startDisplayTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.statusItem.update() }
        }
        timer.resume()
        displayTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayTimer?.cancel()
        scheduler?.suspend()
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// Tear the popover down on close. Combined with rebuilding it on open, this keeps
    /// sizing correct and stops a SwiftUI view graph sitting resident between glances.
    /// Held warm for a minute so repeated glances are instant, then torn down so the
    /// SwiftUI view graph is not resident for the 99% of the time nobody is looking.
    func popoverDidClose(_ notification: Notification) {
        pendingPopoverTeardown?.cancel()
        let teardown = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.popover?.isShown != true else { return }
                self.popover?.contentViewController = nil
                self.popover = nil
                // Hand the freed pages back rather than letting the malloc zones sit on
                // them — vmmap showed ~27 MB parked in empty MALLOC_SMALL regions.
                malloc_zone_pressure_relief(nil, 0)
            }
        }
        pendingPopoverTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: teardown)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Once the window has actually reached the user, it has no further need to outrank
    /// anything — and staying above the normal level would trap Sparkle's update dialog
    /// behind it, as it did until 0.4.5.
    func windowDidBecomeKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.level = .normal
    }

    /// Drop our strong reference so ARC can free the window and, with it, the
    /// NSHostingController and SwiftUI view graph it owns.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === onboardingWindow { onboardingWindow = nil }
        if closing === settingsWindow { settingsWindow = nil }
    }
}
