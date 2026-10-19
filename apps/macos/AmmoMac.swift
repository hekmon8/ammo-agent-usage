import AppKit
import SwiftUI
import QuotaCore
import QuotaPhone
import UserNotifications
import QuotaDesign
import QuotaCollector
import ServiceManagement
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

@main
struct AmmoMacApp: App {
    @NSApplicationDelegateAdaptor(IslandDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            LanguageSensitiveView { Text(L("island.settings.tagline")).padding() }
        }
            .commands {
                CommandGroup(after: .newItem) {
                    Button(L("island.menu.openDashboard")) { delegate.openDashboard() }
                        .keyboardShortcut("o")
                }
            }
    }
}

// AppKit normally clamps panels below the menu bar, which would detach the island.
@MainActor
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class IslandHostingView: NSHostingView<MacStudioIslandRoot> {
    private var islandTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let islandTrackingArea { removeTrackingArea(islandTrackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if let window, bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        islandTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { rootView.onHover(true) }
    override func mouseExited(with event: NSEvent) { rootView.onHover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { rootView.onCollapse() }
}

private final class IslandFrameAnimation: NSAnimation {
    private let applyFrame: @MainActor @Sendable (CGRect) -> Void
    private let startFrame: CGRect
    private let targetFrame: CGRect

    @MainActor
    init(panel: NSPanel, startFrame: CGRect, targetFrame: CGRect, duration: TimeInterval) {
        self.applyFrame = { [weak panel] frame in panel?.setFrame(frame, display: true) }
        self.startFrame = startFrame
        self.targetFrame = targetFrame
        super.init(duration: duration, animationCurve: .linear)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { fatalError("IslandFrameAnimation does not support coding") }

    override var currentProgress: NSAnimation.Progress {
        didSet {
            // This animation starts on the main actor and uses .nonblocking,
            // which delivers progress on that same run loop (never a worker).
            let frame = IslandGeometryTransition.interpolate(
                from: startFrame,
                to: targetFrame,
                progress: IslandGeometryTransition.easeInOut(CGFloat(currentProgress))
            )
            MainActor.assumeIsolated { [applyFrame] in applyFrame(frame) }
        }
    }

}

@MainActor
final class IslandDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(ResetReminderPolicy.prefix) ? [.banner, .list, .sound] : []
    }
    private var panel: NSPanel?
    private var menu: NSStatusItem?
    private var dashboard: NSWindow?
    private var menuProviderPicker: NSWindow?
    private var values: [QuotaPresentation] = []
    private let model = MacModel()
    private let islandViewState = MacIslandViewState()
    private var fixtureMode = false
    private var islandEnabled = true
    private var overviewRows = 1
    private var hoverTask: Task<Void, Never>?
    private var frameAnimation: IslandFrameAnimation?
    private var frameCompletionTask: Task<Void, Never>?
    private var sleeping = false
    private var resizing = false
    private var escapeMonitor: Any?
    private var pendingSmokeNotifications: Set<Notification.Name> = []
    private enum TerminationState { case idle, cleaningUp, ready }
    private var terminationState = TerminationState.idle
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--fixture"), args.indices.contains(index + 1) {
            fixtureMode = true
            do {
                let snapshot = try SnapshotCodec.decode(Data(contentsOf: URL(fileURLWithPath: args[index + 1])))
                // Fixed observation time is only enabled by explicit fixture mode.
                let now = QuotaRules.date(snapshot.capturedAt) ?? Date()
                values = snapshot.windows.map { QuotaPresentation(window: $0, now: now) }
            } catch { fputs("Fixture rejected: \(error)\n", stderr); exit(2) }
        }
        if !fixtureMode { UNUserNotificationCenter.current().delegate = self }
        menu = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = menu?.button {
            let icon = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Ammo")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
        }
        menu?.menu = makeStatusMenu()
        // The status menu is AppKit, not SwiftUI, so it must rebuild itself on
        // a language switch instead of waiting for the next app launch.
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged(_:)), name: L10n.languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged(_:)), name: QuotaAppearanceKeys.menuProvidersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: QuotaAppearanceKeys.islandLayoutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged(_:)), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceOrSleepChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceOrSleepChanged(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let self,
                  event.window === self.panel,
                  self.panel?.isVisible == true,
                  self.islandViewState.interaction.presentation != .collapsed else { return event }
            self.transition(.collapse)
            return nil
        }
        if let index = args.firstIndex(of: "--render-fixtures"), args.indices.contains(index + 1) {
            do { try renderFixtures(to: URL(fileURLWithPath: args[index + 1], isDirectory: true)) }
            catch { fputs("Render failed: \(error)\n", stderr); exit(1) }
            NSApp.terminate(nil); return
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        model.onChange = { [weak self] in
            guard let self else { return }
            self.values = self.model.islandWindows.map { QuotaPresentation(window: $0, now: Date()) }
            // The status menu embeds live quota rows, so it tracks snapshots too.
            self.menu?.menu = self.makeStatusMenu()
            if self.synchronizeOverviewSelection(), self.islandViewState.interaction.presentation == .overview {
                self.reposition(animated: true)
            }
        }
        makeIsland()
        // A manual launch should open the app, while login launches stay quiet.
        if (!fixtureMode || args.contains("--dashboard-smoke")),
           Self.shouldOpenDashboard(arguments: args, event: NSAppleEventManager.shared().currentAppleEvent) {
            openDashboard()
        }
        if !fixtureMode && !args.contains("--smoke") { Task { await model.restore() } }
        if args.contains("--dashboard-smoke"), fixtureMode {
            Task { await runDashboardSmoke() }
        } else if args.contains("--hover-smoke"), fixtureMode {
            Task { await runHoverSmoke() }
        } else if args.contains("--smoke") {
            runBackgroundNotificationSmoke()
        }
    }
    /// Rebuilt on launch, on every language change, and on every snapshot; the
    /// embedded quota rows must not outlive the language or data they render.
    private func makeStatusMenu() -> NSMenu {
        let items = NSMenu()
        let quotaList = NSMenuItem()
        let hosting = NSHostingView(rootView: StatusMenuQuotaSection(
            model: model,
            fixture: fixtureMode ? values : nil,
            onCustomize: { [weak self] in self?.showMenuProviderPicker() }
        ))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        quotaList.view = hosting
        items.addItem(quotaList)
        items.addItem(.separator())
        items.addItem(withTitle: L("island.menu.openDashboard"), action: #selector(openDashboard), keyEquivalent: "o").target = self
        items.addItem(withTitle: L("island.menu.chooseProviders"), action: #selector(showMenuProviderPicker), keyEquivalent: "").target = self
        items.addItem(withTitle: L("island.menu.toggleIsland"), action: #selector(toggleIsland), keyEquivalent: "").target = self
        items.addItem(withTitle: L("island.menu.preferences"), action: #selector(showPreferences), keyEquivalent: ",").target = self
        items.addItem(withTitle: L("island.menu.diagnostics"), action: #selector(showDiagnostics), keyEquivalent: "").target = self
        items.addItem(withTitle: L("island.menu.quit"), action: #selector(quit), keyEquivalent: "q").target = self
        return items
    }
    /// The quota list sits at the top of the menu, so smoke checks resolve
    /// actions by selector instead of a hard-coded item index.
    private func performStatusMenuAction(_ selector: Selector) {
        guard let item = menu?.menu?.items.first(where: { $0.action == selector }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    @objc private func languageChanged(_ notification: Notification) {
        menu?.menu = makeStatusMenu()
    }
    /// Compact editor for which providers appear in the menu quota list;
    /// changes persist immediately and rebuild the status menu.
    @objc private func showMenuProviderPicker() {
        guard !fixtureMode else { return }
        if let menuProviderPicker {
            menuProviderPicker.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("menu.picker.title")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuProvidersPicker(
            providers: MenuProvidersPicker.providers(in: model.snapshot?.windows ?? []),
            initialHidden: Set(UserDefaults.standard.stringArray(forKey: QuotaAppearanceKeys.menuHiddenProviders) ?? [])
        ))
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(closeMenuProviderPicker(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        menuProviderPicker = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func closeMenuProviderPicker(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === menuProviderPicker else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        window.contentView = nil
        menuProviderPicker = nil
    }
    private func renderFixtures(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try render(VStack(alignment: .leading, spacing: 16) {
                Text("Ammo / Paper · Ink").font(.title)
                Text(L("island.fixture.staticValidation")).font(.caption)
                ForEach(values.indices, id: \.self) { QuotaCard(self.values[$0]) }
            }.padding(24).frame(width: 420).background(PaperInk(scheme).canvas)
                .foregroundStyle(PaperInk(scheme).ink).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("components-\(suffix).png"))
            try render(StatusMenuQuotaSection(model: model, fixture: values)
                .background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("status-menu-\(suffix).png"))
            try render(MenuProvidersPicker(
                providers: MenuProvidersPicker.providers(in: values.map(\.window)),
                initialHidden: ["grok"]
            ).frame(width: 380).background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("menu-providers-\(suffix).png"))
            try render(MacStudioDashboard(model: model, fixture: values)
                .frame(width: 980, height: 620)
                .environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("dashboard-\(suffix).png"))
            try render(MacStudioDashboard(model: model, fixture: values)
                .frame(width: 820, height: 700)
                .environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("dashboard-narrow-\(suffix).png"))
            try render(MacStudioDashboard(model: model, fixture: values)
                .frame(width: 1240, height: 700)
                .environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("dashboard-wide-\(suffix).png"))
            try render(ProviderConnectionsView(model: model, fixtureConnections: [
                ProviderConnectionSummary(id: "demo-personal", providerID: "codex", displayName: "Codex",
                    accountAlias: L("island.fixture.demoPersonal"), methodKind: .nativeProvider, statusKind: .bound, isEnabled: true),
                ProviderConnectionSummary(id: "demo-work", providerID: "codex", displayName: "Codex",
                    accountAlias: L("island.fixture.demoWork"), methodKind: .nativeProvider, statusKind: .paused, isEnabled: false),
                ProviderConnectionSummary(id: "demo-glm", providerID: "zai", displayName: "z.ai / GLM",
                    accountAlias: L("island.fixture.demoTeam"), methodKind: .nativeProvider, statusKind: .bound, isEnabled: true),
            ])
                .frame(width: 720, height: 800).background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("connections-\(suffix).png"))
            for providerID in ["codex", "openrouter", "zai", "antigravity"] {
                try render(AddProviderAccountView(fixtureMode: true, model: model, selectedProvider: providerID)
                    .disabled(true).background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                    to: directory.appendingPathComponent("add-\(providerID)-\(suffix).png"))
            }
            try render(IslandAppearanceCard().frame(width: 840).background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("appearance-\(suffix).png"))
            try render(MacSyncOptions(model: model)
                .padding(24).frame(width: 720).background(PaperInk(scheme).canvas).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("sync-\(suffix).png"))
            try render(MacPairingCard(model: model)
                .padding(24).frame(width: 720).environment(\.colorScheme, scheme),
                to: directory.appendingPathComponent("pairing-\(suffix).png"))
            let states: [(String, IslandPresentationState)] = [
                ("collapsed", .collapsed),
                ("overview", .overview),
                ("detail", .detail(windowID: values.first?.window.id ?? "missing")),
            ]
            for (name, state) in states {
                for style in QuotaDisplayStyle.allCases {
                    let styleSuffix = style.rawValue
                    let metrics = IslandLayoutMetrics.metrics(for: state, cameraSize: nil, availableWidth: 1200, displayStyle: style)
                    try render(islandFixture(state: state, cameraSize: nil, size: metrics.size, style: style)
                        .padding(18)
                        .background(PaperInk(scheme).canvas)
                        .environment(\.colorScheme, scheme),
                        to: directory.appendingPathComponent("island-\(name)-\(styleSuffix)-\(suffix).png"))

                    let camera = CGSize(width: 220, height: 38)
                    let notchMetrics = IslandLayoutMetrics.metrics(for: state, cameraSize: camera, availableWidth: 1200, displayStyle: style)
                    try render(islandFixture(state: state, cameraSize: camera, size: notchMetrics.size, style: style)
                        .padding(18)
                        .background(PaperInk(scheme).canvas)
                        .environment(\.colorScheme, scheme),
                        to: directory.appendingPathComponent("island-notch-\(name)-\(styleSuffix)-\(suffix).png"))
                }
            }
            let camera = CGSize(width: 220, height: 38)
            for count in 1...3 {
                let metrics = IslandLayoutMetrics.metrics(
                    for: .collapsed,
                    cameraSize: camera,
                    availableWidth: 1200,
                    visibleSlotCount: count
                )
                try render(islandFixture(
                    state: .collapsed,
                    cameraSize: camera,
                    size: metrics.size,
                    style: .calibrated,
                    slotCount: count
                )
                    .padding(18)
                    .background(PaperInk(scheme).canvas)
                    .environment(\.colorScheme, scheme),
                    to: directory.appendingPathComponent("island-notch-\(count)-slots-calibrated-\(suffix).png"))
            }
        }
        print("PASS: rendered three island styles, 1/2/3 notch slots, all island states, status-menu quota rows, and native components in light and dark")
    }

    private func islandFixture(
        state: IslandPresentationState,
        cameraSize: CGSize?,
        size: CGSize,
        style: QuotaDisplayStyle,
        slotCount: Int = 2
    ) -> some View {
        MacStudioIslandContent(
            model: model,
            fixture: values,
            state: state,
            cameraSize: cameraSize,
            onHover: { _ in },
            onSelectIsland: {},
            onSelectWindow: { _ in },
            onBack: {},
            onCollapse: {},
            selectedAccountID: QuotaAccountGroup.grouped(values).first?.id,
            animationEnabled: false,
            styleOverride: style,
            edgeMotionOverride: false,
            slotCountOverride: slotCount
        )
        .frame(width: size.width, height: size.height, alignment: .top)
    }
    private func render<V: View>(_ content: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { throw ContractErrorForRender.failed }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ContractErrorForRender.failed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ContractErrorForRender.failed }
        try png.write(to: url)
    }
    private enum ContractErrorForRender: Error { case failed }
    private func makeIsland() {
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1); p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        let root = MacStudioIslandRoot(
            model: model,
            viewState: islandViewState,
            fixture: fixtureMode ? values : nil,
            onHover: { [weak self] in self?.islandHoverChanged($0) },
            onSelectIsland: { [weak self] in self?.transition(.islandSelected) },
            onSelectWindow: { [weak self] in self?.transition(.windowSelected($0)) },
            onBack: { [weak self] in self?.transition(.back) },
            onCollapse: { [weak self] in self?.transition(.collapse) },
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onSelectAccount: { [weak self] in self?.selectAccount($0) }
        )
        p.contentView = IslandHostingView(rootView: root)
        panel = p
        synchronizeOverviewSelection()
        reposition()
        p.orderFrontRegardless()
        updateMotionAvailability()
    }
    @objc private func reposition() { reposition(animated: false) }
    private func reposition(animated: Bool, from previousState: IslandPresentationState? = nil) {
        let selected = fixtureMode ? nil : UserDefaults.standard.string(forKey: "islandDisplayID")
        let preferred = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == selected }
        guard let screen = preferred ?? NSScreen.main ?? NSScreen.screens.first, let panel else { return }
        let camera: CGRect?
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            camera = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else { camera = nil }
        let cameraSize = camera.map(\.size)
        let state = islandViewState.interaction.presentation
        let slotCount = UserDefaults.standard.object(forKey: IslandPreferenceKeys.visibleSlotCount) as? Int ?? 2
        let metrics = IslandLayoutMetrics.metrics(
            for: state,
            cameraSize: cameraSize,
            availableWidth: screen.visibleFrame.width,
            overviewRows: overviewRows,
            visibleSlotCount: slotCount,
            displayStyle: QuotaDisplayStyle(storedValue: UserDefaults.standard.string(forKey: QuotaAppearanceKeys.displayStyle) ?? "")
        )
        let frame = IslandPlacement.topCenteredFrame(
            screen: screen.frame,
            visible: screen.visibleFrame,
            safeAreaTop: camera == nil ? screen.safeAreaInsets.top : 0,
            size: metrics.size,
            attachesToScreenTop: camera != nil
        )
        islandViewState.cameraSize = cameraSize
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            frameAnimation?.stop()
            frameCompletionTask?.cancel()
            resizing = true
            updateMotionAvailability()
            let duration = IslandMotionTiming.duration(from: previousState ?? state, to: state)
            let animation = IslandFrameAnimation(
                panel: panel,
                startFrame: panel.frame,
                targetFrame: frame,
                duration: duration
            )
            frameAnimation = animation
            animation.start()
            frameCompletionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, let self else { return }
                panel.setFrame(frame, display: true)
                self.resizing = false
                self.frameAnimation = nil
                self.frameCompletionTask = nil
                self.updateMotionAvailability()
            }
        } else {
            frameAnimation?.stop()
            frameAnimation = nil
            frameCompletionTask?.cancel()
            frameCompletionTask = nil
            resizing = false
            panel.setFrame(frame, display: true)
            updateMotionAvailability()
        }
    }

    @discardableResult
    private func synchronizeOverviewSelection() -> Bool {
        let groups = QuotaAccountGroup.grouped(values)
        let selection = IslandOverviewSelection.resolve(groups, selectedID: islandViewState.selectedAccountID)
        islandViewState.selectedAccountID = selection.groupID
        guard overviewRows != selection.rows else { return false }
        overviewRows = selection.rows
        return true
    }

    private func selectAccount(_ id: String) {
        guard islandViewState.selectedAccountID != id,
              QuotaAccountGroup.grouped(values).contains(where: { $0.id == id }) else { return }
        islandViewState.selectedAccountID = id
        if synchronizeOverviewSelection(), islandViewState.interaction.presentation == .overview {
            reposition(animated: true)
        }
    }
    private func islandHoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        if inside, islandViewState.interaction.presentation == .collapsed {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: IslandMotionTiming.hoverOpenDelay)
                guard !Task.isCancelled else { return }
                self?.transition(.hoverEntered)
            }
        } else if !inside, islandViewState.interaction.presentation != .collapsed {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: IslandMotionTiming.hoverCloseDelay)
                guard !Task.isCancelled else { return }
                // Resizing the hosting view can emit an exit while the pointer
                // still lies inside the island's new native window frame.
                guard let self, self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return }
                self.transition(.hoverExited)
            }
        }
    }
    private func transition(_ interaction: IslandInteraction) {
        hoverTask?.cancel()
        hoverTask = nil
        let previous = islandViewState.interaction.presentation
        let next = IslandStateReducer.reduce(islandViewState.interaction, interaction)
        guard next != islandViewState.interaction else { return }
        if next.presentation == .overview { synchronizeOverviewSelection() }
        islandViewState.interaction = next
        reposition(animated: true, from: previous)
    }
    @objc nonisolated private func screenChanged(_ notification: Notification) {
        let name = notification.name
        let woke = name == NSWorkspace.didWakeNotification
        Task { @MainActor [weak self] in
            guard let self else { return }
            if woke { self.sleeping = false }
            self.reposition()
            if woke {
                if self.islandEnabled { self.panel?.orderFrontRegardless() }
                Task { await self.model.suspend(false) }
            }
            self.updateMotionAvailability()
            self.smokeNotificationHandled(name)
        }
    }
    @objc nonisolated private func spaceOrSleepChanged(_ notification: Notification) {
        let name = notification.name
        let willSleep = name == NSWorkspace.willSleepNotification
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sleeping = willSleep
            if willSleep { self.hideIsland() }
            self.reposition()
            if willSleep { Task { await self.model.suspend(true) } }
            self.updateMotionAvailability()
            self.smokeNotificationHandled(name)
        }
    }
    @objc private func hideIsland() {
        hoverTask?.cancel(); hoverTask = nil
        frameAnimation?.stop(); frameAnimation = nil
        frameCompletionTask?.cancel(); frameCompletionTask = nil
        resizing = false
        islandViewState.interaction = IslandInteractionState()
        panel?.orderOut(nil)
        updateMotionAvailability()
    }
    @objc private func showDiagnostics() { if !fixtureMode { model.showDiagnostics() } }
    @objc nonisolated private func powerChanged(_ notification: Notification) {
        let name = notification.name
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.fixtureMode { self.model.powerStateChanged() }
            self.updateMotionAvailability()
            self.smokeNotificationHandled(name)
        }
    }
    private func updateMotionAvailability() {
        islandViewState.animationEnabled = islandEnabled
            && !sleeping
            && !resizing
            && panel?.isVisible == true
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    /// Synthetic-data-only integration check for native tracking through resize.
    private func runHoverSmoke() async {
        guard let panel, let original = CGEvent(source: nil)?.location,
              let main = NSScreen.screens.first else { return }
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                CGWarpMouseCursorPosition(original)
                fputs("Hover smoke failed: \(message)\n", stderr)
                exit(1)
            }
        }
        func move(to point: CGPoint) {
            let global = CGPoint(x: point.x, y: main.frame.maxY - point.y)
            CGWarpMouseCursorPosition(global)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
        move(to: CGPoint(x: panel.frame.minX + 20, y: panel.frame.minY - 80))
        await settle()
        move(to: CGPoint(x: panel.frame.minX + 20, y: panel.frame.maxY - 10))
        await settle()
        check(islandViewState.interaction.presentation == .overview, "native hover must open")
        transition(.islandSelected)
        await settle()
        move(to: CGPoint(x: panel.frame.minX + 20, y: panel.frame.minY - 80))
        await settle()
        check(islandViewState.interaction.presentation == .collapsed, "clicked overview must close on exit")
        move(to: CGPoint(x: panel.frame.minX + 20, y: panel.frame.maxY - 10))
        await settle()
        transition(.windowSelected(values.first?.window.id ?? "missing"))
        await settle()
        move(to: CGPoint(x: panel.frame.minX + 20, y: panel.frame.minY - 80))
        await settle()
        check(islandViewState.interaction.presentation == .collapsed, "detail must close on exit")
        CGWarpMouseCursorPosition(original)
        print("PASS: native mouse tracking opened overview and closed clicked overview/detail after exit")
        NSApp.terminate(nil)
    }

    /// Exercises real AppKit windows with synthetic data and no account restore.
    private func runDashboardSmoke() async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                fputs("Dashboard smoke failed: \(message)\n", stderr)
                exit(1)
            }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(350)) }
        await settle()
        let background = CommandLine.arguments.contains("--background")
        check((dashboard == nil) == background, "manual launch must open; background launch must stay quiet")
        for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyAEPropData)
            check(!Self.shouldOpenDashboard(arguments: [], event: event), "login/service launch must not open dashboard")
        }
        check(Self.shouldOpenDashboard(arguments: [], event: nil), "manual launch must open dashboard")
        if dashboard == nil { performStatusMenuAction(#selector(openDashboard)) }
        await settle()
        guard let first = dashboard else { check(false, "menu must open dashboard"); return }
        check(first.isVisible && NSApp.activationPolicy() == .regular, "dashboard must be visible and in Dock")
        openDashboard()
        check(dashboard === first, "repeated open must reuse window")
        first.miniaturize(nil)
        await settle()
        check(first.isMiniaturized, "minimize setup")
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        await settle()
        check(dashboard === first && !first.isMiniaturized && first.isVisible, "reopen must restore minimized window")
        NSApp.hide(nil)
        await settle()
        openDashboard()
        await settle()
        check(!NSApp.isHidden && first.isVisible, "open must restore hidden app")
        first.performClose(nil)
        await settle()
        check(dashboard == nil && NSApp.activationPolicy() == .accessory, "close returns to island-only mode")
        check(panel?.isVisible == true, "closing dashboard must preserve island")
        // hasVisibleWindows is true for the island even when the dashboard is closed.
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        await settle()
        check(dashboard?.isVisible == true && dashboard !== first, "Finder reopen must recreate closed dashboard")
        dashboard?.performClose(nil)
        transition(.islandSelected)
        guard let hosting = panel?.contentView as? IslandHostingView else {
            check(false, "island hosting view must exist"); return
        }
        hosting.rootView.onOpenDashboard()
        await settle()
        check(dashboard?.isVisible == true && islandViewState.interaction.presentation == .collapsed,
              "island action must open dashboard and collapse overlay")
        dashboard?.performClose(nil)
        performStatusMenuAction(#selector(openDashboard))
        await settle()
        check(dashboard?.isVisible == true, "menu action must recreate dashboard")
        dashboard?.performClose(nil)
        print("PASS: dashboard manual/background launch, login/service policy, Dock, menu/island entry, singleton, minimize/hide/close/reopen")
        NSApp.terminate(nil)
    }

    private func runBackgroundNotificationSmoke() {
        pendingSmokeNotifications = [
            NSApplication.didChangeScreenParametersNotification,
            .NSProcessInfoPowerStateDidChange,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
        ]
        let defaultCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        DispatchQueue.global(qos: .userInitiated).async {
            precondition(!Thread.isMainThread)
            defaultCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            defaultCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
    }
    private func smokeNotificationHandled(_ name: Notification.Name) {
        guard pendingSmokeNotifications.remove(name) != nil,
              pendingSmokeNotifications.isEmpty else { return }
        hideIsland()
        precondition(panel?.isVisible == false)
        toggleIsland()
        openDashboard()
        dashboard?.performClose(nil)
        precondition(dashboard == nil)
        print("PASS: AppKit initialized; background notification callbacks and dashboard teardown passed; screens=\(NSScreen.screens.count); panelNonactivating=\(panel?.styleMask.contains(.nonactivatingPanel) == true)")
        NSApp.terminate(nil)
    }
    @objc private func showPreferences() {
        guard !fixtureMode else { return }
        let screens = NSScreen.screens
        let selected = UserDefaults.standard.string(forKey: "islandDisplayID")
        let display = NSPopUpButton(frame: NSRect(x: 0, y: 316, width: 340, height: 26))
        display.addItem(withTitle: L("island.prefs.followMainDisplay"))
        for screen in screens { display.addItem(withTitle: screen.localizedName) }
        if let index = screens.firstIndex(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == selected }) { display.selectItem(at: index + 1) }
        let login = NSButton(checkboxWithTitle: L("island.prefs.launchAtLogin"), target: nil, action: nil)
        login.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let service = SMAppService.mainApp
        let initiallyEnabled = service.status == .enabled || service.status == .requiresApproval
        login.state = initiallyEnabled ? .on : .off
        let windows = model.snapshot?.windows ?? []
        let style = NSPopUpButton(frame: NSRect(x: 0, y: 282, width: 340, height: 26))
        for option in QuotaDisplayStyle.allCases {
            style.addItem(withTitle: L("island.prefs.style", option.title))
            style.lastItem?.representedObject = option.rawValue
        }
        let storedStyle = QuotaDisplayStyle(storedValue: UserDefaults.standard.string(forKey: QuotaAppearanceKeys.displayStyle) ?? "")
        style.selectItem(at: QuotaDisplayStyle.allCases.firstIndex(of: storedStyle) ?? 1)
        let edgeMotion = NSButton(checkboxWithTitle: L("island.prefs.edgeMotion"), target: nil, action: nil)
        edgeMotion.frame = NSRect(x: 0, y: 246, width: 340, height: 24)
        edgeMotion.state = (UserDefaults.standard.object(forKey: QuotaAppearanceKeys.edgeMotion) as? Bool ?? true) ? .on : .off
        let slotCount = NSPopUpButton(frame: NSRect(x: 0, y: 210, width: 340, height: 26))
        for count in 1...3 {
            slotCount.addItem(withTitle: L("island.prefs.slotCount", count))
            slotCount.lastItem?.representedObject = count
        }
        let storedSlotCount = IslandSummarySelection.normalizeVisibleCount(
            UserDefaults.standard.object(forKey: IslandPreferenceKeys.visibleSlotCount) as? Int ?? 2
        )
        slotCount.selectItem(at: storedSlotCount - 1)
        func windowPicker(key: String, y: CGFloat, title: String) -> NSPopUpButton {
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: y, width: 340, height: 26))
            picker.addItem(withTitle: L("island.picker.auto", title))
            for window in windows {
                picker.addItem(withTitle: L("island.picker.windowOption", title, window.accountAlias, window.shortDisplayName))
                picker.lastItem?.representedObject = window.id
            }
            if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty {
                if let index = windows.firstIndex(where: { $0.id == id }) {
                    picker.selectItem(at: index + 1)
                } else {
                    picker.addItem(withTitle: L("island.picker.missing", title))
                    picker.lastItem?.representedObject = id
                    picker.selectItem(at: picker.numberOfItems - 1)
                }
            }
            return picker
        }
        let left = windowPicker(key: IslandPreferenceKeys.leftWindowID, y: 176, title: L("island.prefs.left"))
        let right = windowPicker(key: IslandPreferenceKeys.rightWindowID, y: 142, title: L("island.prefs.right"))
        let third = windowPicker(key: IslandPreferenceKeys.thirdWindowID, y: 108, title: L("island.prefs.bottom"))
        let period = NSButton(checkboxWithTitle: L("island.prefs.showPeriod"), target: nil, action: nil)
        period.frame = NSRect(x: 0, y: 72, width: 340, height: 24)
        period.state = (UserDefaults.standard.object(forKey: "islandShowPeriod") as? Bool ?? true) ? .on : .off
        let reset = NSButton(checkboxWithTitle: L("island.prefs.showReset"), target: nil, action: nil)
        reset.frame = NSRect(x: 0, y: 38, width: 340, height: 24)
        reset.state = UserDefaults.standard.bool(forKey: "islandShowReset") ? .on : .off
        let refreshLabel = NSTextField(labelWithString: L("settings.refresh.interval"))
        refreshLabel.frame = NSRect(x: 0, y: 354, width: 100, height: 20)
        let refresh = NSPopUpButton(frame: NSRect(x: 110, y: 350, width: 230, height: 26))
        refresh.setAccessibilityLabel(L("settings.refresh.interval"))
        for interval in CollectorRefreshInterval.allCases {
            refresh.addItem(withTitle: L("settings.refresh.minutes", interval.rawValue))
            refresh.lastItem?.representedObject = interval.rawValue
        }
        refresh.selectItem(at: CollectorRefreshInterval.allCases.firstIndex(of: model.refreshInterval) ?? 2)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 388))
        for control in [refreshLabel, refresh, display, style, edgeMotion, slotCount, left, right, third, period, reset, login] { view.addSubview(control) }
        let alert = NSAlert(); alert.messageText = L("island.prefs.title")
        alert.informativeText = L("island.prefs.explain")
        alert.accessoryView = view; alert.addButton(withTitle: L("island.prefs.save")); alert.addButton(withTitle: L("island.prefs.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let minutes = refresh.selectedItem?.representedObject as? Int,
           let interval = CollectorRefreshInterval(rawValue: minutes) {
            model.setRefreshInterval(interval)
        }
        let index = display.indexOfSelectedItem - 1
        if screens.indices.contains(index), let id = screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            UserDefaults.standard.set(id.stringValue, forKey: "islandDisplayID")
        } else { UserDefaults.standard.removeObject(forKey: "islandDisplayID") }
        for (key, picker) in [
            (IslandPreferenceKeys.leftWindowID, left),
            (IslandPreferenceKeys.rightWindowID, right),
            (IslandPreferenceKeys.thirdWindowID, third),
        ] {
            UserDefaults.standard.set(picker.selectedItem?.representedObject as? String ?? "", forKey: key)
        }
        UserDefaults.standard.set(style.selectedItem?.representedObject as? String ?? QuotaDisplayStyle.calibrated.rawValue,
                                  forKey: QuotaAppearanceKeys.displayStyle)
        UserDefaults.standard.set(edgeMotion.state == .on, forKey: QuotaAppearanceKeys.edgeMotion)
        UserDefaults.standard.set(slotCount.selectedItem?.representedObject as? Int ?? 2,
                                  forKey: IslandPreferenceKeys.visibleSlotCount)
        UserDefaults.standard.set(period.state == .on, forKey: "islandShowPeriod")
        UserDefaults.standard.set(reset.state == .on, forKey: "islandShowReset")
        reposition()
        guard (login.state == .on) != initiallyEnabled else { return }
        do {
            if login.state == .on { try service.register() } else { try service.unregister() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let failure = NSAlert(); failure.messageText = L("island.prefs.partialSaveTitle")
            failure.informativeText = L("island.prefs.partialSaveDetail")
            failure.runModal()
        }
    }
    @objc private func toggleIsland() {
        islandEnabled = panel?.isVisible != true
        if !islandEnabled {
            hideIsland()
        } else {
            sleeping = false
            islandViewState.interaction = IslandInteractionState()
            reposition()
            panel?.orderFrontRegardless()
            updateMotionAvailability()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }
    private static func shouldOpenDashboard(arguments: [String], event: NSAppleEventDescriptor?) -> Bool {
        if arguments.contains("--background") { return false }
        if event?.eventID == kAEOpenApplication,
           let launchReason = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue,
           launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem {
            return false
        }
        return true
    }
    @objc func openDashboard() {
        transition(.collapse)
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if let dashboard {
            if dashboard.isMiniaturized { dashboard.deminiaturize(nil) }
            dashboard.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = LanguageSensitiveView { MacStudioDashboard(model: model, fixture: fixtureMode ? values : nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Ammo"; window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("quota-dashboard")
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.contentView = NSHostingView(rootView: content); window.center()
        dashboard = window
        NotificationCenter.default.addObserver(self, selector: #selector(closeDashboard(_:)), name: NSWindow.willCloseNotification, object: window)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func closeDashboard(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        window.contentView = nil
        dashboard = nil
        NSApp.setActivationPolicy(.accessory)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .ready:
            return .terminateNow
        case .cleaningUp:
            return .terminateCancel
        case .idle:
            terminationState = .cleaningUp
            // Returning cancel releases AppKit's modal termination loop so the
            // MainActor cleanup can run; the completed cleanup re-enters once.
            Task {
                await model.stop()
                terminationState = .ready
                sender.terminate(nil)
            }
            return .terminateCancel
        }
    }
}

/// "1 window" vs "%lld windows" — the menu surface prints small counts.
private func windowCountLabel(_ count: Int) -> String {
    count == 1 ? L("island.overview.windowCountOne", count) : L("island.overview.windowCount", count)
}

/// Status-menu quota list, one merged block per provider (design philosophy:
/// design/menu-quota-rings.md). The header carries a concentric ring cluster —
/// one ring per percent window — and every row keeps its own circular mark, so
/// each window stays an independent 0–100 scale that is never averaged.
/// Windows without a ratio (balances, resets) render a quiet dot instead of a
/// fake progress. Snapshot order survives both between groups and inside them.
private struct StatusMenuQuotaSection: View {
    @ObservedObject var model: MacModel
    let fixture: [QuotaPresentation]?
    var onCustomize: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    private static let groupLimit = 5
    private static let lineLimit = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let values = fixture ?? (model.snapshot?.windows ?? []).map { QuotaPresentation(window: $0, now: context.date) }
            let hidden = Set(UserDefaults.standard.stringArray(forKey: QuotaAppearanceKeys.menuHiddenProviders) ?? [])
            let groups = QuotaProviderGroup.groups(values, hiddenProviderIDs: hidden)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L("island.menu.quotaHeader")).font(.system(size: 11, weight: .semibold))
                    if hidden.count > 0 {
                        Text(L("island.menu.hiddenCount", hidden.count)).font(.system(size: 10))
                    }
                    Spacer(minLength: 8)
                    if !values.isEmpty {
                        Text(windowCountLabel(values.count)).font(.system(size: 10))
                    }
                    if let onCustomize {
                        Button(action: onCustomize) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 18, height: 18)
                                .background(PaperInk(scheme).track, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PaperInk(scheme).muted)
                        .help(L("island.menu.chooseProviders"))
                        .accessibilityLabel(L("island.menu.chooseProviders"))
                    }
                }
                .foregroundStyle(PaperInk(scheme).muted)
                if values.isEmpty {
                    Label(L("island.menu.quotaEmpty"), systemImage: "gauge")
                        .font(.system(size: 11))
                        .foregroundStyle(PaperInk(scheme).muted)
                } else if groups.isEmpty {
                    Label(L("island.menu.allHidden"), systemImage: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(PaperInk(scheme).muted)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups.prefix(Self.groupLimit)) { group in
                            StatusMenuProviderGroup(group: group, lineLimit: Self.lineLimit)
                        }
                    }
                    if groups.count > Self.groupLimit {
                        let overflow = groups.dropFirst(Self.groupLimit).flatMap(\.values).count
                        Text(L("island.menu.quotaMore", overflow))
                            .font(.system(size: 10))
                            .foregroundStyle(PaperInk(scheme).muted)
                    }
                    Text(L("island.menu.quotaFootnote"))
                        .font(.system(size: 9))
                        .foregroundStyle(PaperInk(scheme).muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(width: 292, alignment: .leading)
        }
    }
}

private struct StatusMenuProviderGroup: View {
    let group: QuotaProviderGroup
    let lineLimit: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let identity = ProviderCatalog.identity(for: group.providerID)
        let sections = group.accountSections
        let shown: [QuotaPresentation] = sections.isEmpty
            ? Array(group.values.prefix(lineLimit))
            : sections.flatMap { Array($0.values.prefix(lineLimit)) }
        let extra = group.values.count - shown.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProviderMark(providerID: group.providerID, size: 20)
                Text(identity.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PaperInk(scheme).ink)
                    .lineLimit(1)
                Text(windowCountLabel(group.values.count))
                    .font(.system(size: 10))
                    .foregroundStyle(PaperInk(scheme).muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                QuotaRingCluster(group.values, diameter: 30)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(identity.displayName), \(windowCountLabel(group.values.count))")
            let sections = group.accountSections
            if sections.isEmpty {
                ForEach(shown, id: \.window.id) { StatusMenuWindowLine($0) }
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    // Two accounts may share an alias; label it once.
                    if index == 0 || sections[index - 1].alias != section.alias {
                        Text(section.alias)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PaperInk(scheme).muted)
                            .lineLimit(1)
                            .padding(.leading, 28)
                    }
                    ForEach(Array(section.values.prefix(lineLimit)), id: \.window.id) { StatusMenuWindowLine($0) }
                }
            }
            if extra > 0 {
                Text(L("island.menu.quotaGroupMore", extra))
                    .font(.system(size: 10))
                    .foregroundStyle(PaperInk(scheme).muted)
                    .padding(.leading, 28)
            }
        }
    }
}

private struct StatusMenuWindowLine: View {
    let value: QuotaPresentation
    @Environment(\.colorScheme) private var scheme

    init(_ value: QuotaPresentation) { self.value = value }

    /// Windows without any reset information render no second tier.
    private var showsCountdown: Bool {
        value.state == .authRequired || value.window.resetDescription(now: Date(), compact: true) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                QuotaWindowMark(value, diameter: 12)
                Text(value.window.shortDisplayName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PaperInk(scheme).ink.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(value.number)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(QuotaVisualState(value).color(for: scheme))
                    .lineLimit(1)
                    .layoutPriority(2)
            }
            .padding(.leading, 28)
            if showsCountdown {
                ResetLabel(value, compact: true)
                    .font(.system(size: 9.5))
                    .foregroundStyle(PaperInk(scheme).muted)
                    .lineLimit(1)
                    .padding(.leading, 47)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("design.a11y.limitRow", value.window.shortDisplayName, "\(value.valueHeading) \(value.number)", value.status))
    }
}

/// Edits which providers appear in the menu quota list. The hidden set is the
/// persisted source of truth: every change writes UserDefaults and posts
/// menuProvidersChanged so the AppKit status menu rebuilds immediately.
/// Provider rows are fixed at open time; the status menu itself tracks data.
private struct MenuProvidersPicker: View {
    let providers: [(id: String, name: String, count: Int)]
    @State private var hidden: Set<String>
    @Environment(\.colorScheme) private var scheme

    init(providers: [(id: String, name: String, count: Int)], initialHidden: Set<String>) {
        self.providers = providers
        _hidden = State(initialValue: initialHidden)
    }

    static func providers(in windows: [QuotaWindow]) -> [(id: String, name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for window in windows {
            if counts[window.providerId] == nil { order.append(window.providerId) }
            counts[window.providerId, default: 0] += 1
        }
        return order.map { id in (id, ProviderCatalog.identity(for: id).displayName, counts[id] ?? 0) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        let palette = PaperInk(scheme)
        VStack(alignment: .leading, spacing: 14) {
            Text(L("menu.picker.subtitle"))
                .font(.caption)
                .foregroundStyle(palette.muted)
            HStack(spacing: 14) {
                Button(L("menu.picker.showAll")) { hidden.removeAll() }
                Button(L("menu.picker.hideAll")) { hidden.formUnion(providers.map(\.id)) }
                Spacer()
            }
            .buttonStyle(.link)
            Divider()
            if providers.isEmpty {
                Label(L("island.menu.quotaEmpty"), systemImage: "gauge")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(providers, id: \.id) { provider in
                            Toggle(isOn: Binding(
                                get: { !hidden.contains(provider.id) },
                                set: { shown in
                                    if shown { hidden.remove(provider.id) } else { hidden.insert(provider.id) }
                                }
                            )) {
                                HStack(spacing: 10) {
                                    ProviderMark(providerID: provider.id, size: 26)
                                    Text(provider.name).lineLimit(1)
                                    Spacer()
                                    Text(windowCountLabel(provider.count))
                                        .font(.caption)
                                        .foregroundStyle(palette.muted)
                                }
                            }
                            .toggleStyle(.switch)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            Text(L("menu.picker.footnote"))
                .font(.caption2)
                .foregroundStyle(palette.muted)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .frame(minHeight: 440)
        .background(palette.canvas)
        .foregroundStyle(palette.ink)
        .onChange(of: hidden) { _, newValue in
            UserDefaults.standard.set(newValue.sorted(), forKey: QuotaAppearanceKeys.menuHiddenProviders)
            NotificationCenter.default.post(name: QuotaAppearanceKeys.menuProvidersChanged, object: nil)
        }
    }
}

struct MacPairingCard: View {
    @ObservedObject var model: MacModel
    @Environment(\.colorScheme) private var scheme
    @State private var showsServiceSwitch = false

    var body: some View {
        let palette = PaperInk(scheme)
        VStack(alignment: .leading, spacing: 16) {
            Text(L("island.pairing.title")).studioType(.section)
            Text(L("island.pairing.intro"))
                .font(.caption).foregroundStyle(palette.muted)

            if !model.cloudConnected {
                PairingStep(number: 1, title: L("island.pairing.step1Title"), detail: L("island.pairing.step1Detail"))
                SyncConnectionView(model: model).frame(height: 460)
            } else if model.rotationPending {
                PairingStep(number: 1, title: L("island.pairing.rotationTitle"), detail: L("island.pairing.rotationDetail"))
                Button(model.rotationBusy ? L("island.pairing.rotating") : L("island.pairing.resumeRotation")) { Task { await model.resumeRotation() } }
                    .disabled(model.rotationBusy)
            } else {
                serviceRow(palette)
                if showsServiceSwitch {
                    SyncConnectionView(model: model, allowsReplacement: true)
                }
                PairingStep(number: 1, title: L("island.pairing.createTitle"), detail: L("island.pairing.createDetail"))
                if model.pairingLink.isEmpty {
                    Button(L("island.pairing.createLink")) { model.createPairing() }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        if let image = pairingQRCode(model.pairingLink) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                                .accessibilityLabel(L("island.pairing.qrAccessibility"))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            PairingStep(number: 2, title: L("island.pairing.openOnPhoneTitle"), detail: L("island.pairing.openOnPhoneDetail"))
                            Button(L("island.pairing.copyLink")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.pairingLink, forType: .string)
                            }
                            Text(model.pairingOrigin).font(.caption.monospaced()).textSelection(.enabled)
                            Text(L("island.pairing.fingerprint", model.pairingFingerprint)).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                    PairingStep(number: 3, title: L("island.pairing.approveTitle"), detail: L("island.pairing.approveDetail"))
                    Button(L("island.pairing.checkPhone")) { model.approvePairing() }
                }
                if !model.pairingLink.isEmpty {
                    PairingStep(number: 4, title: L("island.pairing.finishTitle"), detail: L("island.pairing.finishDetail"))
                }
                Button(L("island.pairing.manageDevices")) { model.manageDevices() }
                Divider()
                Toggle(L("island.pairing.backgroundMonitoring"), isOn: Binding(
                    get: { model.projectionEnabled }, set: { model.setProjectionEnabled($0) }
                )).disabled(model.projectionBusy || model.rotationBusy || model.cloudConnecting || model.workerSwitchPending)
                Text(L("island.pairing.projectionExplain"))
                    .font(.caption).foregroundStyle(palette.muted)
                Text(model.liveUpdateMessage.text).font(.caption).foregroundStyle(palette.muted)
            }
        }
        .padding(18)
        .studioSurface(radius: 18)
        .studioType(.body)
        .buttonStyle(StudioRaisedButtonStyle())

    }

    /// Current sync service with the entry point that replaces it (official ↔
    /// self-hosted URL); previously this was only configurable before connecting.
    private func serviceRow(_ palette: PaperInk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("island.pairing.serviceTitle")).font(.headline)
                Spacer()
                Button(showsServiceSwitch ? L("island.action.collapse") : L("island.pairing.changeService")) {
                    showsServiceSwitch.toggle()
                }.disabled(model.cloudConnecting || model.rotationBusy)
            }
            Text(model.syncServiceIsOfficial == true ? L("settings.sync.officialName") : L("settings.sync.selfHostName"))
                .font(.caption).foregroundStyle(palette.muted)
            if let endpoint = model.syncEndpoint {
                Text(endpoint.absoluteString)
                    .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(palette.muted)
            }
        }
    }
}

private struct PairingStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 24, height: 24).background(Color.primary.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

func pairingQRCode(_ string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
}
