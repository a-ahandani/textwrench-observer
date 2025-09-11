#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// Minimal production selection observer.
// Option + left mouse up triggers selection capture (immediate + two delayed passes).

final class SelectionObserver {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseUpTimer: Timer?
    private var retrievalTimers: [DispatchWorkItem] = []
    private var lastSentJSON: String?
    private var optionDown = false
    private let passes: [TimeInterval] = [0.0, 0.05, 0.15]
    private var sequence: UInt64 = 0
    private var lastHadSelection: Bool = false
    private var selectionAnchor: CGPoint? // position where selection was emitted
    private let cancelDistanceX: CGFloat = 130
    private let cancelDistanceY: CGFloat = 80
    private var selectionTimestamp: TimeInterval = 0
    private let minLifetimeBeforeCancel: TimeInterval = 0.25 // don't cancel immediately
    private var lastMovementCheckPos: CGPoint?
    private var lastMovementCheckTime: TimeInterval = 0
    private let movementCheckInterval: TimeInterval = 0.04 // sample throttling
    private var mouseUpPosition: CGPoint?
    private var currentModifiers: Set<String> = []
    private var selectionModifiers: [String] = []
    private var lastWindowInfo: [String: Any]? // store window info for paste targeting

    init() {
        setupEventTap()
        setupAXObserver()
    listenForProcessedText()
    }

    func run() { CFRunLoopRun() }

    private func setupEventTap() {
        let mask = (1 << CGEventType.leftMouseUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.mouseMoved.rawValue) |
                   (1 << CGEventType.leftMouseDragged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .listenOnly,
                                     eventsOfInterest: CGEventMask(mask),
                                     callback: { _, type, event, refcon in
            let me = Unmanaged<SelectionObserver>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(eventType: type, event: event)
            return Unmanaged.passRetained(event)
        }, userInfo: ref)
        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(eventType: CGEventType, event: CGEvent) {
        if eventType == .flagsChanged {
            optionDown = event.flags.contains(.maskAlternate)
            updateCurrentModifiers(from: event.flags)
        }
        if eventType == .leftMouseUp { mouseReleased() }
        if eventType == .mouseMoved || eventType == .leftMouseDragged { trackMovement(event) }
    }

    private func mouseReleased() {
        guard optionDown else { return }
    // Capture legacy top-left coordinate at mouse up
    mouseUpPosition = legacyMouseTopLeftPoint()
    // Snapshot modifiers at mouse up
    selectionModifiers = Array(currentModifiers).sorted()
        mouseUpTimer?.invalidate()
        mouseUpTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { [weak self] _ in
            self?.startRetrieval()
        }
    }

    private func startRetrieval() {
        sequence &+= 1
        retrievalTimers.forEach { $0.cancel() }
        retrievalTimers.removeAll()
        for (i, delay) in passes.enumerated() {
            let seq = sequence
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.sequence == seq else { return }
                self.attempt(passIndex: i)
            }
            retrievalTimers.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func attempt(passIndex: Int) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return }
        let element = focused as! AXUIElement
        if let (text, isEditable) = readSelection(element: element) {
            emit(text: text, isEditable: isEditable)
        } else if passIndex == passes.count - 1 {
            // On the final pass, if we previously had a selection but now none is detected,
            // emit an empty signal to mirror the legacy behavior where a deselection is sent
            // once the selection collapses.
            if lastHadSelection { emitEmptyIfNeeded() }
        }
    }

    private func readSelection(element: AXUIElement) -> (String, Bool)? {
        var editable = false
        // Check AXEditable if present
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success,
           let e = editableRef as? Bool { editable = e }

        // Direct selected text
        var selRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success {
            if let s = selRef as? String, hasContent(s) { return (cleaned(s), editable) }
            if CFGetTypeID(selRef) == CFAttributedStringGetTypeID(), let a = selRef as? NSAttributedString, hasContent(a.string) { return (cleaned(a.string), editable) }
        }
        // Range + value
        var rangeRef: CFTypeRef?
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID(),
           let full = valueRef as? String, !full.isEmpty {
            var r = CFRange(location: 0, length: 0)
            if AXValueGetValue(rv as! AXValue, .cfRange, &r), r.length > 0, r.location + r.length <= full.count {
                let ns = full as NSString
                let sub = ns.substring(with: NSRange(location: r.location, length: r.length))
                if hasContent(sub) { return (cleaned(sub), editable) }
            }
        }
        // Parameterized
        if let text = parameterizedRangeString(element: element), hasContent(text) { return (cleaned(text), editable) }
        return nil
    }

    private func parameterizedRangeString(element: AXUIElement) -> String? {
        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let rv = selRangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var r = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rv as! AXValue, .cfRange, &r), r.length > 0 else { return nil }
        if var copy = Optional(r), let axVal = AXValueCreate(.cfRange, &copy) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, axVal, &out) == .success {
                if let s = out as? String { return s }
                if CFGetTypeID(out) == CFAttributedStringGetTypeID(), let a = out as? NSAttributedString { return a.string }
            }
        }
        return nil
    }

    private func emit(text: String, isEditable: Bool) {
        guard hasContent(text) else { return }
    let pos = mouseUpPosition ?? legacyMouseTopLeftPoint()
        var payload: [String: Any] = [
            "text": text,
            "position": ["x": pos.x, "y": pos.y],
            "isEditable": isEditable
        ]
    if !selectionModifiers.isEmpty { payload["modifiers"] = selectionModifiers }
        if let win = currentWindowInfo() { payload["window"] = win }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastSentJSON else { return }
        print(json)
        fflush(stdout)
        lastSentJSON = json
        lastHadSelection = true
    selectionAnchor = pos // use legacy top-left based capture point for movement anchoring
        selectionTimestamp = CFAbsoluteTimeGetCurrent()
        lastMovementCheckPos = selectionAnchor
        lastMovementCheckTime = selectionTimestamp
        retrievalTimers.forEach { $0.cancel() }
        retrievalTimers.removeAll()
    if let win = payload["window"] as? [String: Any] { lastWindowInfo = win }
    }

    private func cleaned(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func hasContent(_ s: String) -> Bool {
        let stripped = s
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setupAXObserver() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        var observer: AXObserver?
        let pid = app.processIdentifier
        if AXObserverCreate(pid, { _,_,_,_ in }, &observer) == .success, let obs = observer {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }

    private func emitEmptyIfNeeded() {
        let pos = mouseUpPosition ?? legacyMouseTopLeftPoint()
        let payload: [String: Any] = [
            "text": "",
            "position": ["x": pos.x, "y": pos.y]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8), json != lastSentJSON {
            print(json)
            fflush(stdout)
            lastSentJSON = json
        }
        lastHadSelection = false
        selectionAnchor = nil
        selectionTimestamp = 0
        lastMovementCheckPos = nil
    mouseUpPosition = nil
    selectionModifiers = []
    }

    private func trackMovement(_ event: CGEvent) {
        guard lastHadSelection, let anchor = selectionAnchor else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Throttle checks
        if now - lastMovementCheckTime < movementCheckInterval { return }
        lastMovementCheckTime = now
        let current = event.location
        lastMovementCheckPos = current
        // Enforce minimum lifetime so quick tiny adjustments don't cancel
        if now - selectionTimestamp < minLifetimeBeforeCancel { return }
        let dx = abs(current.x - anchor.x)
        let dy = abs(current.y - anchor.y)
        if dx > cancelDistanceX || dy > cancelDistanceY { emitEmptyIfNeeded() }
    }

    // Legacy top-left coordinate conversion (flips Y within screen bounds)
    private func legacyMouseTopLeftPoint() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.frame {
            let flippedY = f.origin.y + f.size.height - mouse.y
            return CGPoint(x: mouse.x, y: flippedY)
        }
        // Fallback using primary screen height
        if let h = NSScreen.main?.frame.height {
            return CGPoint(x: mouse.x, y: h - mouse.y)
        }
        return mouse
    }

    // MARK: - Modifier Handling
    private func updateCurrentModifiers(from flags: CGEventFlags) {
        var mods: Set<String> = []
        if flags.contains(.maskShift) { mods.insert("shift") }
        if flags.contains(.maskControl) { mods.insert("control") }
        if flags.contains(.maskAlternate) { mods.insert("option") }
        if flags.contains(.maskCommand) { mods.insert("command") }
        currentModifiers = mods
    }

    // MARK: - Window Info (minimal)
    private func currentWindowInfo() -> [String: Any]? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        var info: [String: Any] = [
            "appName": front.localizedName ?? "unknown",
            "appPID": pid,
            "windowTitle": ""
        ]
        let appEl = AXUIElementCreateApplication(pid)
        var mainWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
           let win = mainWindowRef {
            let winEl = win as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(winEl, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String { info["windowTitle"] = t }
        }
        return info
    }

    // MARK: - Paste Handling (simplified)
    private func listenForProcessedText() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async { self?.handleIncomingText(line) }
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        // Accept either plain text or { text:..., appPID:... }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            copyAndPaste(text: text)
            return
        }
        let processedText = (json["text"] as? String) ?? text
        let pid = json["appPID"] as? pid_t
        copyAndPaste(text: processedText, targetAppPID: pid)
    }

    private func copyAndPaste(text: String, targetAppPID: pid_t? = nil) {
        copyToClipboard(text)
        performPaste(targetAppPID: targetAppPID ?? (lastWindowInfo?["appPID"] as? pid_t))
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func performPaste(targetAppPID: pid_t?) {
        guard let pid = targetAppPID else {
            // Fallback: just issue paste globally
            issuePasteKeystroke()
            return
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        // Clear selection popup state
        emitEmptyIfNeeded()
        // Activate and focus target app
        activateApplication(pid: pid)
        focusMainWindow(pid: pid)
        // Small delay to allow focus
        usleep(120_000)
        issuePasteKeystroke()
        // Re-enable tap after slight delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let tap = self?.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    private func issuePasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let tapLoc = CGEventTapLocation.cghidEventTap
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: tapLoc)
        usleep(30_000)
        keyUp?.post(tap: tapLoc)
    }

    private func activateApplication(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if !app.activate(options: [.activateAllWindows]) {
            let script = """
            tell application "System Events"
                set frontmost of process whose unix id is \(pid) to true
            end tell
            """
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func focusMainWindow(pid: pid_t) {
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef) == .success,
           let win = windowRef {
            let windowEl = win as! AXUIElement
            AXUIElementSetAttributeValue(windowEl, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(windowEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(150_000)
        }
    }
}

let observer = SelectionObserver()
observer.run()