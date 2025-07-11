#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// MARK: - Global Variables
var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""
var lastSentSignal: String?
var selectionChangedHandler: ((Bool, Int) -> Void)?
var mouseUpSelectionCheckTimer: Timer?
var mouseIsDragging = false
var lastWindowInfo: [String: Any]? = nil

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
}

// MARK: - Mouse Event Handling
private func globalMouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pos = event.location

    switch type {
    case .leftMouseDown, .rightMouseDown:
        mouseIsDragging = false

    case .leftMouseDragged, .rightMouseDragged:
        mouseIsDragging = true

    case .leftMouseUp, .rightMouseUp:
        mouseUpSelectionCheckTimer?.invalidate()
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let wasDrag = mouseIsDragging
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { _ in
            selectionChangedHandler?(wasDrag, clickCount)
        }
        mouseIsDragging = false

    case .mouseMoved:
        if popupShown, let popupPos = lastPopupPosition {
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 300 || dy > 300 {
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

    private func setupMouseEventListener() {
        startMouseEventListener { [weak self] wasDrag, clickCount in
            self?.handleSelectionOrDeselection(wasDrag: wasDrag, clickCount: clickCount)
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
        var isEditable = false
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
            
            // Check editable status
            var editableRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success {
                isEditable = editableRef as? Bool ?? false
            }
            
            if !isEditable {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                   let role = roleRef as? String {
                    isEditable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
                }
            }
            
            if !isEditable {
                var actionsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXActions" as CFString, &actionsRef) == .success,
                   let actions = actionsRef as? [String] {
                    isEditable = actions.contains("AXSetSelectedText") || 
                                actions.contains("AXInsertText")
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
                    "isEditable": isEditable,
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
            
            // Check editable status
            var editableRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, "AXEditable" as CFString, &editableRef) == .success {
                isEditable = editableRef as? Bool ?? false
            }
            
            if !isEditable {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXRoleAttribute as CFString, &roleRef) == .success,
                   let role = roleRef as? String {
                    isEditable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
                }
            }
            
            if !isEditable {
                var actionsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, "AXActions" as CFString, &actionsRef) == .success,
                   let actions = actionsRef as? [String] {
                    isEditable = actions.contains("AXSetSelectedText") || 
                                actions.contains("AXInsertText")
                }
            }

            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "isEditable": isEditable,
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
        
        // Temporarily disable event tap
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

    func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int) {
        guard let selection = SelectionObserver.currentSelection() else {
            if popupShown {
                sendResetSignal()
            }
            return
        }
        
        let selectedText = selection["text"] as? String ?? ""
        let isEditable = selection["isEditable"] as? Bool ?? false
        let windowInfo = selection["window"] as? [String: Any]
        lastWindowInfo = windowInfo
        
        // Define cases where we should try clipboard
        let shouldTryClipboard: Bool
        
        if selectedText.isEmpty {
            shouldTryClipboard = false
        } else if selectedText == " " {
            shouldTryClipboard = true
        } else if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shouldTryClipboard = true
        } else {
            shouldTryClipboard = false
        }
        
        let finalShouldTry = shouldTryClipboard && (wasDrag || clickCount == 2 || clickCount == 3)
        // NSLog("Selected text: '\(selectedText)' isEditable: \(isEditable). Should try clipboard: \(finalShouldTry)")

        if finalShouldTry {
            if let clipboardText = getSelectedTextViaClipboard(), !clipboardText.isEmpty {
                if !clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let mousePos = currentMouseTopLeftPosition()
                    lastSelectionText = clipboardText
                    lastPopupPosition = CGPoint(x: mousePos.x, y: mousePos.y)
                    popupShown = true
                    
                    let selectionData: [String: Any] = [
                        "text": clipboardText,
                        "position": ["x": mousePos.x, "y": mousePos.y],
                        "isEditable": isEditable,
                        "window": windowInfo ?? [:]
                    ]
                    sendSignalIfChanged(selectionData)
                }
                return
            }
        }
        
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if (wasDrag || clickCount == 2 || clickCount == 3), hasMeaningfulText, selectedText != lastSelectionText {
            lastSelectionText = selectedText
            let mousePos = currentMouseTopLeftPosition()
            lastPopupPosition = CGPoint(x: mousePos.x, y: mousePos.y)
            popupShown = true
            
            let selectionData: [String: Any] = [
                "text": selectedText,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "isEditable": isEditable,
                "window": windowInfo ?? [:]
            ]
            sendSignalIfChanged(selectionData)
        }
        else if !hasMeaningfulText, popupShown {
            sendResetSignal()
        }
    }

    func startMouseEventListener(selectionChanged: @escaping (Bool, Int) -> Void) {
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
                // Parse the incoming JSON which may contain both text and appPID
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    
                    let text = json["text"] as? String ?? line
                    let appPID = json["appPID"] as? pid_t
                    
                    self.copyToClipboard(text)
                    self.performPaste(targetAppPID: appPID)
                } else {
                    // Fallback for plain text input
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
        // Disable event tap during paste operation to prevent interference
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        
        defer {
            // Re-enable event tap after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.ensureEventTapActive()
            }
        }
        
        sendResetSignal()
        NSLog("=== Starting paste operation ===")
        
        let pidToUse = targetAppPID ?? (lastWindowInfo?["appPID"] as? pid_t)
        
        if let pid = pidToUse {
            NSLog("Targeting app with PID: \(pid)")
            
            // Get the application reference
            let appRef = AXUIElementCreateApplication(pid)
            
            // Activate the app
            if let app = NSRunningApplication(processIdentifier: pid) {
                let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSLog("App activation \(activated ? "successful" : "failed")")
                
                // Longer delay for app to become active
                usleep(500000) // 500ms
                
                // Verify activation
                if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                    let success = frontmostApp.processIdentifier == pid
                    NSLog("Frontmost app: \(frontmostApp.localizedName ?? "unknown") (\(frontmostApp.processIdentifier)) - \(success ? "Correct" : "Incorrect")")
                    
                    if success {
                        // Focus the main window
                        var windowRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef) == .success,
                        let window = windowRef {
                            AXUIElementSetAttributeValue(window as! AXUIElement, kAXMainAttribute as CFString, kCFBooleanTrue)
                            usleep(300000) // 300ms for window focus
                        }
                    }
                }
            }
        }
        
        // Perform the paste
        NSLog("Executing paste command")
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        let keyVDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyVDown?.flags = .maskCommand
        let keyVUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyVUp?.flags = .maskCommand
        
        keyVDown?.post(tap: loc)
        usleep(100000) // 100ms between key down/up
        keyVUp?.post(tap: loc)
        
        NSLog("=== Paste operation completed ===")
    }

    func run() {
        CFRunLoopRun()
    }
}

let observer = SelectionObserver()
observer.run()