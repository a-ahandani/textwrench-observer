#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// MARK: - Global Variables
var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""
var lastSentSignal: String?
var selectionChangedHandler: ((Bool, Int, Bool) -> Void)?  // Added Bool for modifierKeyPressed
var mouseUpSelectionCheckTimer: Timer?
var mouseIsDragging = false
var lastWindowInfo: [String: Any]? = nil

// Variables for delayed signal sending
var pendingSelectionText: String? = nil
var pendingSelectionTimer: Timer? = nil
var initialMousePosition: CGPoint? = nil
let positionThreshold: CGFloat = 50.0 // pixels
let timeThreshold: TimeInterval = 0.3 // seconds

// Track if Option key was pressed during drag/up
var modifierKeyWasPressed = false


// MARK: - Helper Functions
func currentMouseTopLeftPosition() -> (x: CGFloat, y: CGFloat) {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
    guard let screenFrame = screen?.frame else {
        let h = NSScreen.main?.frame.height ?? 0
        return (mouseLocation.x, h - mouseLocation.y)
    }
    let flippedY = screenFrame.origin.y + screenFrame.size.height - mouseLocation.y
    return (mouseLocation.x, flippedY)
}

func sendSignalIfChanged(_ dict: [String: Any]) {
    if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        if jsonString != lastSentSignal {
            print(jsonString, terminator: "\n")
            fflush(stdout)
            lastSentSignal = jsonString
        }
    }
}

func sendResetSignal() {
    let mousePos = currentMouseTopLeftPosition()
    let empty: [String: Any] = [
        "text": "",
        "position": ["x": mousePos.x, "y": mousePos.y]
    ]
    sendSignalIfChanged(empty)
    popupShown = false
    lastPopupPosition = nil
    lastSelectionText = ""
    lastWindowInfo = nil

    // Cancel any pending selection
    pendingSelectionText = nil
    pendingSelectionTimer?.invalidate()
    pendingSelectionTimer = nil
    initialMousePosition = nil
}

// MARK: - Mouse Event Callback
private func globalMouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pos = event.location
    let currentPos = CGPoint(x: pos.x, y: pos.y)

    switch type {
    case .leftMouseDown, .rightMouseDown:
        mouseIsDragging = false
        modifierKeyWasPressed = event.flags.contains(.maskAlternate)  // Option key down at mouse down

    case .leftMouseDragged, .rightMouseDragged:
        mouseIsDragging = true
        // Update modifier key state during drag
        modifierKeyWasPressed = event.flags.contains(.maskAlternate)

    case .leftMouseUp, .rightMouseUp:
        mouseUpSelectionCheckTimer?.invalidate()
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let wasDrag = mouseIsDragging
        // Check modifier key on mouse up as well
        modifierKeyWasPressed = event.flags.contains(.maskAlternate)
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { _ in
            selectionChangedHandler?(wasDrag, clickCount, modifierKeyWasPressed)
        }
        mouseIsDragging = false

    case .mouseMoved:
        // Update mouse position but don't cancel here - we'll check in the timer
        if popupShown, let popupPos = lastPopupPosition {
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 130 || dy > 80 {
                sendResetSignal()
            }
        }
    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - SelectionObserver Class
class SelectionObserver {
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isProcessingClipboard = false
    private var lastMousePosition: CGPoint?

    init() {
        setupMouseEventListener()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowFocusChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        listenForProcessedText()
    }

    private func handlePendingSelection(modifierPressed: Bool) {
        guard let pendingText = pendingSelectionText else { return }
        
        // Get current mouse position
        let currentMousePos = NSEvent.mouseLocation
        let initialPos = initialMousePosition ?? currentMousePos
        
        // Calculate distance moved
        let dx = abs(currentMousePos.x - initialPos.x)
        let dy = abs(currentMousePos.y - initialPos.y)
        
        // Only send if movement is <= threshold
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
            
            // Add modifier flag ONLY if modifier key pressed during selection
            if modifierPressed {
                selectionData["modifier"] = "option"
            }
            
            sendSignalIfChanged(selectionData)
        }
        
        pendingSelectionText = nil
        pendingSelectionTimer = nil
        initialMousePosition = nil
    }

    private func setupMouseEventListener() {
        startMouseEventListener { [weak self] wasDrag, clickCount, modifierPressed in
            self?.handleSelectionOrDeselection(wasDrag: wasDrag, clickCount: clickCount, modifierPressed: modifierPressed)
        }
    }

    @objc func windowFocusChanged(_ notification: Notification? = nil) {
        if popupShown {
            sendResetSignal()
        }
        ensureEventTapActive()
    }

    func ensureEventTapActive() {
        if let eventTap = eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    static func currentSelection() -> [String: Any]? {
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
        
        // First try focused element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
           let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            
            // Get window title if available
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
               let window = windowRef {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    windowInfo["windowTitle"] = title
                }
            }
            
            // Get selected text
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "isEditable": false,
                    "window": windowInfo
                ]
            }
        }
        
        // Fallback to main window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
           let window = windowRef {
            let windowElement = window as! AXUIElement
            
            // Get window title
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String {
                windowInfo["windowTitle"] = title
            }
            
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "isEditable": false,
                    "window": windowInfo
                ]
            }
        }
        
        return nil
    }

    func getSelectedTextViaClipboard() -> String? {
        guard !isProcessingClipboard else {
            return nil
        }
        
        isProcessingClipboard = true
        defer { isProcessingClipboard = false }
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.ensureEventTapActive()
            }
        }
        
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount
        
        pasteboard.clearContents()
        
        let currentApp = NSWorkspace.shared.frontmostApplication
        currentApp?.activate(options: [])
        
        usleep(50000)
        
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        for attempt in 1...3 {
            let keyCDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
            keyCDown?.flags = .maskCommand
            let keyCUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
            keyCUp?.flags = .maskCommand
            
            keyCDown?.post(tap: loc)
            usleep(20000)
            keyCUp?.post(tap: loc)
            
            let startTime = CFAbsoluteTimeGetCurrent()
            let timeout: CFTimeInterval = 0.3
            
            while CFAbsoluteTimeGetCurrent() - startTime < timeout {
                if pasteboard.changeCount > originalChangeCount {
                    if let copiedText = pasteboard.string(forType: .string) {
                        pasteboard.clearContents()
                        if let originalContent = originalContent {
                            pasteboard.setString(originalContent, forType: .string)
                        }
                        return copiedText
                    }
                }
                usleep(10000)
            }
            
            if attempt < 3 {
                usleep(100000)
            }
        }
        
        pasteboard.clearContents()
        if let originalContent = originalContent {
            pasteboard.setString(originalContent, forType: .string)
        }
        
        return nil
    }

    func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int, modifierPressed: Bool) {
        guard let selection = SelectionObserver.currentSelection() else {
            if popupShown {
                sendResetSignal()
            }
            return
        }
        
        let selectedText = selection["text"] as? String ?? ""
        let windowInfo = selection["window"] as? [String: Any]
        lastWindowInfo = windowInfo
        
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if (wasDrag || clickCount == 2 || clickCount == 3), hasMeaningfulText, selectedText != lastSelectionText {
            // Store initial mouse position when selection is made
            let mousePos = NSEvent.mouseLocation
            initialMousePosition = CGPoint(x: mousePos.x, y: mousePos.y)
            
            // Schedule the signal to be sent after time threshold, pass modifierPressed flag
            pendingSelectionText = selectedText
            pendingSelectionTimer?.invalidate()
            pendingSelectionTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
                self?.handlePendingSelection(modifierPressed: modifierPressed)
            }
        }
        else if !hasMeaningfulText, popupShown {
            sendResetSignal()
        }
    }

    func startMouseEventListener(selectionChanged: @escaping (Bool, Int, Bool) -> Void) {
        selectionChangedHandler = selectionChanged

        let mouseEventMask =
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mouseEventMask),
            callback: globalMouseEventCallback,
            userInfo: nil
        )

        if let eventTap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.setupMouseEventListener()
            }
        }
    }

    func listenForProcessedText() {
        DispatchQueue.global().async {
            while let line = readLine() {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    
                    let text = json["text"] as? String ?? line
                    let appPID = json["appPID"] as? pid_t
                    
                    self.copyToClipboard(text)
                    self.performPaste(targetAppPID: appPID)
                } else {
                    self.copyToClipboard(line)
                    self.performPaste(targetAppPID: nil)
                }
            }
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func performPaste(targetAppPID: pid_t?) {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.ensureEventTapActive()
            }
        }
        
        sendResetSignal()
        
        guard let pid = targetAppPID ?? (lastWindowInfo?["appPID"] as? pid_t) else {
            return
        }
        
        let appRef = AXUIElementCreateApplication(pid)
        
        if let app = NSRunningApplication(processIdentifier: pid) {
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
        
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef) == .success,
        let window = windowRef {
            AXUIElementSetAttributeValue(window as! AXUIElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window as! AXUIElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(150000)
        }
        
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: loc)
        usleep(30000)
        keyUp?.post(tap: loc)
    }

    func run() {
        CFRunLoopRun()
    }
}

let observer = SelectionObserver()
observer.run()
