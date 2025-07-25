#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// MARK: - Constants
let kAXEditableAttribute = "AXEditable"

// MARK: - Modifier State Tracking
struct ModifierFlags: OptionSet {
    let rawValue: Int
    
    static let shift     = ModifierFlags(rawValue: 1 << 0)
    static let control   = ModifierFlags(rawValue: 1 << 1)
    static let option    = ModifierFlags(rawValue: 1 << 2)
    static let command   = ModifierFlags(rawValue: 1 << 3)
    
    init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    init(cgEventFlags: CGEventFlags) {
        var flags = ModifierFlags()
        if cgEventFlags.contains(.maskShift)    { flags.insert(.shift) }
        if cgEventFlags.contains(.maskControl)  { flags.insert(.control) }
        if cgEventFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgEventFlags.contains(.maskCommand)   { flags.insert(.command) }
        self = flags
    }
}

class ModifierState {
    private(set) var currentFlags: ModifierFlags = []
    private let debounceInterval: TimeInterval = 0.05
    private var debounceTimer: Timer?
    
    func update(with event: CGEvent) {
        let newFlags = ModifierFlags(cgEventFlags: event.flags)
        
        // Immediate update for mouse down events
        if [.leftMouseDown, .rightMouseDown].contains(event.type) {
            currentFlags = newFlags
            return
        }
        
        // Debounced update for other events
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.currentFlags = newFlags
        }
    }
    
    func lockCurrentState() -> ModifierFlags {
        debounceTimer?.invalidate()
        return currentFlags
    }
}

// MARK: - Main Implementation
class SelectionObserver {
    // State tracking
    private var lastPopupPosition: CGPoint?
    private var popupShown: Bool = false
    private var lastSelectionText: String = ""
    private var lastSentSignal: String?
    private var mouseIsDragging = false
    private var lastWindowInfo: [String: Any]?
    
    // Modifier state
    let modifierState = ModifierState()
    
    // Delayed selection handling
    private var pendingSelectionText: String?
    private var pendingSelectionTimer: Timer?
    private var initialMousePosition: CGPoint?
    private let positionThreshold: CGFloat = 50.0
    private let timeThreshold: TimeInterval = 0.3
    
    // Event handling
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseUpSelectionCheckTimer: Timer?
    private var isProcessingClipboard = false
    
    // MARK: - Initialization
    init() {
        setupMouseEventListener()
        setupApplicationNotifications()
        listenForProcessedText()
    }
    
    deinit {
        invalidateTimers()
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
    }
    
    // MARK: - Setup
    private func setupApplicationNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowFocusChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    private func invalidateTimers() {
        mouseUpSelectionCheckTimer?.invalidate()
        pendingSelectionTimer?.invalidate()
    }
    
    // MARK: - Mouse Event Handling
    private func setupMouseEventListener() {
        let mouseEventMask =
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
        
        let observerRef = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mouseEventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let observer = Unmanaged<SelectionObserver>.fromOpaque(refcon!).takeUnretainedValue()
                return observer.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observerRef
        )
        
        if let eventTap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            print("Error: Failed to create event tap. Accessibility permissions may be required.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.setupMouseEventListener()
            }
        }
    }
    
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        modifierState.update(with: event)
        
        switch type {
        case .leftMouseDown, .rightMouseDown:
            mouseIsDragging = false
            
        case .leftMouseDragged, .rightMouseDragged:
            mouseIsDragging = true
            
        case .leftMouseUp, .rightMouseUp:
            handleMouseUp(event: event)
            
        case .mouseMoved:
            handleMouseMoved(event: event)
            
        default:
            break
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleMouseUp(event: CGEvent) {
        mouseUpSelectionCheckTimer?.invalidate()
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let wasDrag = mouseIsDragging
        let modifiers = modifierState.lockCurrentState()
        
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 0.08,
            repeats: false
        ) { [weak self] _ in
            self?.handleSelectionOrDeselection(
                wasDrag: wasDrag,
                clickCount: clickCount,
                modifiers: modifiers
            )
        }
        mouseIsDragging = false
    }
    
    private func handleMouseMoved(event: CGEvent) {
        if popupShown, let popupPos = lastPopupPosition {
            let pos = event.location
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 130 || dy > 80 {
                sendResetSignal()
            }
        }
    }
    
    // MARK: - Selection Handling
    private func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int, modifiers: ModifierFlags) {
        guard let selection = getCurrentSelection() else {
            if popupShown { sendResetSignal() }
            return
        }
        
        let selectedText = selection["text"] as? String ?? ""
        lastWindowInfo = selection["window"] as? [String: Any]
        
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if (wasDrag || clickCount >= 2), hasMeaningfulText, selectedText != lastSelectionText {
            initialMousePosition = NSEvent.mouseLocation
            pendingSelectionText = selectedText
            pendingSelectionTimer?.invalidate()
            
            pendingSelectionTimer = Timer.scheduledTimer(
                withTimeInterval: timeThreshold,
                repeats: false
            ) { [weak self] _ in
                self?.handlePendingSelection(modifiers: modifiers)
            }
        } else if !hasMeaningfulText, popupShown {
            sendResetSignal()
        }
    }
    
    private func handlePendingSelection(modifiers: ModifierFlags) {
        guard let pendingText = pendingSelectionText else { return }
        
        let currentMousePos = NSEvent.mouseLocation
        let initialPos = initialMousePosition ?? currentMousePos
        
        let dx = abs(currentMousePos.x - initialPos.x)
        let dy = abs(currentMousePos.y - initialPos.y)
        
        if dx <= positionThreshold && dy <= positionThreshold {
            let mousePos = currentMouseTopLeftPosition()
            lastSelectionText = pendingText
            lastPopupPosition = CGPoint(x: mousePos.x, y: mousePos.y)
            popupShown = true
            
            var selectionData: [String: Any] = [
                "text": pendingText,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "isEditable": false,
                "window": lastWindowInfo ?? [:]
            ]
            
            if !modifiers.isEmpty {
                var modifierStrings: [String] = []
                if modifiers.contains(.shift)    { modifierStrings.append("shift") }
                if modifiers.contains(.control)  { modifierStrings.append("control") }
                if modifiers.contains(.option)   { modifierStrings.append("option") }
                if modifiers.contains(.command)  { modifierStrings.append("command") }
                
                selectionData["modifiers"] = modifierStrings
            }
            
            sendSignalIfChanged(selectionData)
        }
        
        pendingSelectionText = nil
        pendingSelectionTimer = nil
        initialMousePosition = nil
    }
    
    // MARK: - Selection Utilities
    private func getCurrentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowInfo: [String: Any] = [
            "appName": frontApp.localizedName ?? "unknown",
            "appPID": pid,
            "windowTitle": ""
        ]
        
        // Try focused element first
        if let focusedElement = getFocusedElement(appElement),
           let (text, updatedWindowInfo) = getSelectedText(from: focusedElement, windowInfo: windowInfo) {
            windowInfo = updatedWindowInfo
            let mousePos = currentMouseTopLeftPosition()
            return [
                "text": text,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "isEditable": isEditableElement(focusedElement),
                "window": windowInfo
            ]
        }
        
        // Fallback to main window
        if let mainWindow = getMainWindow(appElement),
           let (text, updatedWindowInfo) = getSelectedText(from: mainWindow, windowInfo: windowInfo) {
            windowInfo = updatedWindowInfo
            let mousePos = currentMouseTopLeftPosition()
            return [
                "text": text,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "isEditable": false,
                "window": windowInfo
            ]
        }
        
        return nil
    }
    
    private func getFocusedElement(_ appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        return (focusedElement as! AXUIElement)
    }
    
    private func getMainWindow(_ appElement: AXUIElement) -> AXUIElement? {
        var mainWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow) == .success else {
            return nil
        }
        return (mainWindow as! AXUIElement)
    }
    
    private func getSelectedText(from element: AXUIElement, windowInfo: [String: Any]) -> (String, [String: Any])? {
        var updatedWindowInfo = windowInfo
        var selectedText: CFTypeRef?
        
        // Get window title if available
        if let window = getWindowForElement(element),
           let title = getWindowTitle(window) {
            updatedWindowInfo["windowTitle"] = title
        }
        
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
              let text = selectedText as? String else {
            return nil
        }
        
        return (text, updatedWindowInfo)
    }
    
    private func getWindowForElement(_ element: AXUIElement) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success else {
            return nil
        }
        return (window as! AXUIElement)
    }
    
    private func getWindowTitle(_ window: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
    
    private func isEditableElement(_ element: AXUIElement) -> Bool {
        var editable: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEditableAttribute as CFString, &editable) == .success else {
            return false
        }
        return editable as? Bool ?? false
    }
    
    // MARK: - Clipboard Fallback
    private func getSelectedTextViaClipboard() -> String? {
        guard !isProcessingClipboard else { return nil }
        isProcessingClipboard = true
        defer { isProcessingClipboard = false }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.ensureEventTapActive() } }
        
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount
        
        pasteboard.clearContents()
        NSWorkspace.shared.frontmostApplication?.activate(options: [])
        
        usleep(50000) // 50ms delay
        
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        for _ in 1...3 {
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) // C key
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
            keyUp?.flags = .maskCommand
            
            keyDown?.post(tap: loc)
            usleep(20000) // 20ms
            keyUp?.post(tap: loc)
            
            let startTime = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - startTime < 0.3 { // 300ms timeout
                if pasteboard.changeCount > originalChangeCount,
                   let copiedText = pasteboard.string(forType: .string) {
                    pasteboard.clearContents()
                    if let content = originalContent {
                        pasteboard.setString(content, forType: .string)
                    }
                    return copiedText
                }
                usleep(10000) // 10ms
            }
            usleep(100000) // 100ms between attempts
        }
        
        pasteboard.clearContents()
        if let content = originalContent {
            pasteboard.setString(content, forType: .string)
        }
        return nil
    }
    
    // MARK: - Signal Handling
    private func sendSignalIfChanged(_ dict: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8),
              jsonString != lastSentSignal else {
            return
        }
        
        print(jsonString, terminator: "\n")
        fflush(stdout)
        lastSentSignal = jsonString
    }
    
    private func sendResetSignal() {
        let mousePos = currentMouseTopLeftPosition()
        let empty: [String: Any] = [
            "text": "",
            "position": ["x": mousePos.x, "y": mousePos.y]
        ]
        sendSignalIfChanged(empty)
        resetSelectionState()
    }
    
    private func resetSelectionState() {
        popupShown = false
        lastPopupPosition = nil
        lastSelectionText = ""
        lastWindowInfo = nil
        pendingSelectionText = nil
        pendingSelectionTimer?.invalidate()
        pendingSelectionTimer = nil
        initialMousePosition = nil
    }
    
    // MARK: - Position Utilities
    private func currentMouseTopLeftPosition() -> (x: CGFloat, y: CGFloat) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screenFrame = screen?.frame else {
            let h = NSScreen.main?.frame.height ?? 0
            return (mouseLocation.x, h - mouseLocation.y)
        }
        let flippedY = screenFrame.origin.y + screenFrame.size.height - mouseLocation.y
        return (mouseLocation.x, flippedY)
    }
    
    // MARK: - Paste Handling
    private func listenForProcessedText() {
        DispatchQueue.global().async { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async {
                    self?.handleIncomingText(line)
                }
            }
        }
    }
    
    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            copyAndPaste(text: text)
            return
        }
        
        let processedText = json["text"] as? String ?? text
        let targetPID = json["appPID"] as? pid_t
        
        copyAndPaste(text: processedText, targetAppPID: targetPID)
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
        guard let pid = targetAppPID else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.ensureEventTapActive() } }
        
        sendResetSignal()
        activateApplication(pid: pid)
        focusMainWindow(pid: pid)
        
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: loc)
        usleep(30000) // 30ms
        keyUp?.post(tap: loc)
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
            task.launch()
            task.waitUntilExit()
        }
    }
    
    private func focusMainWindow(pid: pid_t) {
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else {
            return
        }
        
        let windowElement = window as! AXUIElement
        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(150000) // 150ms
    }
    
    // MARK: - Utilities
    @objc private func windowFocusChanged(_ notification: Notification? = nil) {
        if popupShown {
            sendResetSignal()
        }
        ensureEventTapActive()
    }
    
    private func ensureEventTapActive() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    // MARK: - Main Loop
    func run() {
        CFRunLoopRun()
    }
}

// MARK: - Application Entry Point
let observer = SelectionObserver()
observer.run()