// FocusDim: dims every window except the one you are using, on all screens.
// Lives in the menu bar. Needs Accessibility access to know which window is focused.
//
// Design
// ------
// 1. Which window is focused? Ask macOS through the Accessibility API
//    (the app's AXFocusedWindow), the same answer VoiceOver uses. No guessing
//    from window sizes or stacking order.
// 2. Each screen has two dim layers:
//    - "cover": floats above all normal windows and dims the whole screen.
//      Used on screens that do NOT show the focused window.
//    - "under": sits directly below the focused window in the stack.
//      Used on screens that show the focused window.
//    Full-screen Spaces: macOS keeps this app's layers above a full-screen app and
//    ignores ordering them below it. macOS reports full screen through the
//    window's AXFullScreen attribute, so the under layer stays off there
//    (nothing is behind a full-screen app anyway).
// 3. The stacking order is checked against the real window list on every
//    update and fixed if anything slipped between the focused window and
//    the under layer (Space switches, new windows). If it can't be fixed,
//    the under layer stays off: the focused window is never dimmed.
// 4. Updates run on focus/move/resize events, app switches, Space changes,
//    and a 0.25 s safety check.
// If the focused window cannot be found, nothing is dimmed (fail bright).
import Cocoa
import Carbon
import ServiceManagement
import ApplicationServices

// Maps an Accessibility window to its window-server ID. Private but long-stable
// (used by most macOS window managers).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

final class DimLayer: NSWindow {
    private(set) var targetAlpha: CGFloat = 0
    var wid: CGWindowID { CGWindowID(windowNumber) }

    init(screen: NSScreen, level: NSWindow.Level) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .black
        alphaValue = 0
        ignoresMouseEvents = true          // clicks go straight through
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setTarget(_ a: CGFloat, animated: Bool) {
        guard abs(a - targetAlpha) > 0.001 else { return }
        targetAlpha = a
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = a
            }
        } else {
            alphaValue = a
        }
    }
}

struct ScreenLayers {
    let bounds: CGRect           // window-server coordinates (top-left origin)
    let cover: DimLayer
    let under: DimLayer
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement,
                        _ note: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let app = Unmanaged<App>.fromOpaque(refcon).takeUnretainedValue()
    app.scheduleUpdate()
}

final class App: NSObject, NSApplicationDelegate {
    private var screens: [ScreenLayers] = []
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var updatePending = false
    private var failedOrders = 0
    private var trusted = false
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
        // Never let a frozen app freeze FocusDim.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        buildLayers()
        buildMenu()
        registerHotKey()

        // First launch: start at login automatically.
        if defaults.object(forKey: "loginSetUp") == nil {
            defaults.set(true, forKey: "loginSetUp")
            try? SMAppService.mainApp.register()
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        // Ask for Accessibility access if missing (shows the system prompt).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        refreshMenuState()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(self, selector: #selector(scheduleUpdate), name: name, object: nil)
        }

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    // MARK: layers

    private func buildLayers() {
        for s in screens { s.cover.orderOut(nil); s.under.orderOut(nil) }
        screens = NSScreen.screens.map { scr in
            ScreenLayers(bounds: CGDisplayBounds(scr.displayID),
                         cover: DimLayer(screen: scr, level: .floating),
                         under: DimLayer(screen: scr, level: .normal))
        }
    }

    @objc private func screensChanged() { buildLayers(); update() }

    @objc func scheduleUpdate() {
        if updatePending { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.updatePending = false
            self?.update()
        }
    }

    private func hideAll(animated: Bool = true) {
        for s in screens {
            s.cover.setTarget(0, animated: animated)
            s.under.setTarget(0, animated: animated)
        }
    }

    // MARK: core

    private func update() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted { trusted = nowTrusted; refreshMenuState() }
        guard enabled, trusted else { hideAll(); return }

        guard let app = NSWorkspace.shared.frontmostApplication else { hideAll(); return }
        let pid = app.processIdentifier
        if pid == myPID { return }          // our own menu is open: keep things as they are
        observe(pid: pid)

        let list = windowList()
        guard let focused = focusedWindow(pid: pid, list: list) else { hideAll(); return }

        // Decide per screen: does it show the focused window?
        var underIDs = Set<CGWindowID>()
        for s in screens {
            let i = focused.bounds.intersection(s.bounds)
            if !i.isNull && i.width >= 1 && i.height >= 1 { underIDs.insert(s.under.wid) }
        }

        // Fix stacking: the under layers must sit directly below the focused window.
        //
        // Full-screen Spaces: macOS keeps menu-bar apps' all-Spaces windows ABOVE the
        // full-screen app and ignores ordering them below it. macOS itself reports
        // full screen through the window's AXFullScreen attribute; there is nothing
        // behind a full-screen app to dim, so the under layer stays off there.
        //
        // Safety rule: the focused window must never be dimmed. If the stack is still
        // wrong after a reorder attempt, the under layer stays off until it is right.
        var underOff = Set<CGWindowID>()
        if focused.fullScreen {
            underOff = underIDs
        } else if !underIDs.isEmpty {
            if stackIsCorrect(list: list, target: focused.id, under: underIDs) {
                failedOrders = 0
            } else {
                failedOrders += 1
                for s in screens where underIDs.contains(s.under.wid) {
                    s.under.order(.below, relativeTo: Int(focused.id))
                }
                if failedOrders >= 2 { underOff = underIDs }
            }
        }

        let d = CGFloat(dim)
        for s in screens {
            let showsFocus = underIDs.contains(s.under.wid)
            let underOn = showsFocus && !underOff.contains(s.under.wid)
            s.under.setTarget(underOn ? d : 0, animated: true)
            s.cover.setTarget(showsFocus ? 0 : d, animated: true)
        }
    }

    /// On-screen windows, front to back.
    private func windowList() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                    kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private func info(_ w: [String: Any]) -> (id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect)? {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let layer = w[kCGWindowLayer as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return (id, pid, layer, r)
    }

    /// The focused window of the app, as macOS reports it, if it is on screen.
    private func focusedWindow(pid: pid_t, list: [[String: Any]]) -> (id: CGWindowID, bounds: CGRect, fullScreen: Bool)? {
        let axApp = AXUIElementCreateApplication(pid)
        var axWin: AXUIElement?
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr as CFString, &v) == .success,
               let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
                axWin = (v as! AXUIElement)
                break
            }
        }
        guard let axWin else { return nil }

        var fsVal: CFTypeRef?
        let fullScreen = AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsVal) == .success
            && (fsVal as? Bool) == true

        let windows = list.compactMap(info).filter { $0.pid == pid }

        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(axWin, &wid) == .success, wid != 0,
           let w = windows.first(where: { $0.id == wid }) {
            return (w.id, w.bounds, fullScreen)
        }

        // Backup: match the window's exact position and size.
        guard let frame = axFrame(axWin) else { return nil }
        if let w = windows.first(where: {
            abs($0.bounds.minX - frame.minX) < 1 && abs($0.bounds.minY - frame.minY) < 1 &&
            abs($0.bounds.width - frame.width) < 1 && abs($0.bounds.height - frame.height) < 1
        }) { return (w.id, w.bounds, fullScreen) }
        return nil
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
              AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// True if, going down the stack from the focused window, the next normal
    /// windows are exactly our under layers.
    private func stackIsCorrect(list: [[String: Any]], target: CGWindowID, under: Set<CGWindowID>) -> Bool {
        let all = list.compactMap(info)
        guard let ti = all.firstIndex(where: { $0.id == target }) else { return false }
        var seen = Set<CGWindowID>()
        for w in all[(ti + 1)...] where w.layer == 0 {
            guard under.contains(w.id) else { return false }
            seen.insert(w.id)
            if seen.count == under.count { return true }
        }
        return false
    }

    // MARK: events from the focused app

    private func observe(pid: pid_t) {
        guard pid != observedPID else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
        }
        observer = nil
        observedPID = pid

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowCreatedNotification, kAXWindowMovedNotification,
                  kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification] {
            AXObserverAddNotification(obs, el, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    // MARK: menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        accessItem = NSMenuItem(title: "Allow Accessibility access…", action: #selector(openAccess), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)

        enabledItem = NSMenuItem(title: "Dim other windows", action: #selector(toggle), keyEquivalent: "d")
        enabledItem.keyEquivalentModifierMask = [.command, .shift]
        enabledItem.target = self
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
        refreshMenuState()
    }

    private func refreshMenuState() {
        guard statusItem != nil else { return }
        accessItem.isHidden = trusted
        enabledItem.state = enabled ? .on : .off
        let name = !trusted ? "exclamationmark.circle" : (enabled ? "circle.lefthalf.filled" : "circle")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "FocusDim")
    }

    /// Global shortcut: Command + Shift + D. Works in any app.
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
        refreshMenuState()
        update()
    }

    @objc private func openAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
        let d = CGFloat(dim)
        for l in screens.flatMap({ [$0.cover, $0.under] }) where l.targetAlpha > 0 {
            l.setTarget(d, animated: false)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
