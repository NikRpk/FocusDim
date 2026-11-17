// FocusDim: dims every window except the one you are using, on all screens.
// Lives in the menu bar. No permissions needed.
import Cocoa
import Carbon
import ServiceManagement

final class Overlay: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .black
        alphaValue = 0
        ignoresMouseEvents = true          // clicks go straight through
        hasShadow = false
        level = .normal
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class App: NSObject, NSApplicationDelegate {
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var timer: Timer?
    private var lastWID: CGWindowID = 0
    private var visible = false
    private let myPID = ProcessInfo.processInfo.processIdentifier
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var dim: Double {
        get { defaults.object(forKey: "dim") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "dim") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildOverlays()
        buildMenu()
        registerHotKey()

        // First launch: start at login automatically.
        if defaults.object(forKey: "loginSetUp") == nil {
            defaults.set(true, forKey: "loginSetUp")
            try? SMAppService.mainApp.register()
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(forceRefresh),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(forceRefresh),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: overlays

    private func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        lastWID = 0
        visible = false
    }

    @objc private func screensChanged() { buildOverlays(); tick() }
    @objc private func forceRefresh() { lastWID = 0; tick() }

    /// Screen frame in window-server coordinates (origin top-left of the main screen).
    private func cgFrame(of o: Overlay) -> CGRect {
        let f = o.frame
        let mainH = NSScreen.screens.first?.frame.height ?? f.height
        return CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
    }

    /// Top normal window of the frontmost app (front-to-back order),
    /// plus the frames of all that app's visible windows.
    private func frontWindow() -> (id: CGWindowID, rects: [CGRect])? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var topID: CGWindowID?
        var rects: [CGRect] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.width >= 80, r.height >= 80 else { continue }
            if topID == nil { topID = id }
            rects.append(r)
        }
        guard let id = topID else { return nil }
        return (id, rects)
    }

    /// True if the app's windows fill the whole screen.
    /// Full-screen windows on a notched MacBook start below the notch, and some
    /// full-screen apps (Chrome) split into several full-width strips, so join them.
    private func isFullScreen(_ rects: [CGRect], on screen: CGRect, notch: CGFloat) -> Bool {
        let strips = rects.filter {
            $0.minX <= screen.minX + 2 && $0.maxX >= screen.maxX - 2 &&
            $0.maxY > screen.minY && $0.minY < screen.maxY
        }
        guard let first = strips.first else { return false }
        let u = strips.dropFirst().reduce(first) { $0.union($1) }
        return u.minY <= screen.minY + notch + 2 && u.maxY >= screen.maxY - 2
    }

    private func tick() {
        guard enabled else { fade(overlays.map { _ in 0 }); return }
        // Our own menu is open: keep things as they are.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == myPID { return }

        guard let front = frontWindow() else {
            fade(overlays.map { _ in 0 }); lastWID = 0; return
        }
        if front.id != lastWID {
            for o in overlays { o.order(.below, relativeTo: Int(front.id)) }
            lastWID = front.id
        }
        // A full-screen focused app fills its screen: no dimming there.
        fade(overlays.map { o in
            isFullScreen(front.rects, on: cgFrame(of: o),
                         notch: o.screen?.safeAreaInsets.top ?? 0) ? 0 : dim
        })
    }

    private func fade(_ targets: [Double]) {
        let changed = zip(overlays, targets).filter { abs(Double($0.0.alphaValue) - $0.1) > 0.001 }
        if changed.isEmpty { return }
        visible = targets.contains { $0 > 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            for (o, t) in changed { o.animator().alphaValue = CGFloat(t) }
        }
    }

    // MARK: menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled",
                                           accessibilityDescription: "FocusDim")
        let menu = NSMenu()

        enabledItem = NSMenuItem(title: "Dim other windows", action: #selector(toggle), keyEquivalent: "d")
        enabledItem.keyEquivalentModifierMask = [.command, .shift]
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)

        loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let label = NSMenuItem(title: "Dim level", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)

        let slider = NSSlider(value: dim, minValue: 0.1, maxValue: 0.9,
                              target: self, action: #selector(sliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: 180, height: 22)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 216, height: 30))
        holder.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = holder
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FocusDim", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let name = enabled ? "circle.lefthalf.filled" : "circle"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "FocusDim")
    }

    /// Global shortcut: Command + Shift + D. Works in any app, no permission needed.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<App>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x46444D31), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func toggle() {
        enabled.toggle()
        enabledItem.state = enabled ? .on : .off
        updateIcon()
        lastWID = 0
        tick()
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
        loginItem.state = svc.status == .enabled ? .on : .off
    }

    @objc private func sliderMoved(_ s: NSSlider) {
        dim = s.doubleValue
        if enabled && visible { for o in overlays where o.alphaValue > 0 { o.alphaValue = CGFloat(dim) } }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
