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

        // First try focused element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
           let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            
            // Method 1: Check AXEditable attribute
            var editableRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success {
                isEditable = editableRef as? Bool ?? false
            }
            
            // Method 2: Check role (for text fields)
            if !isEditable {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                   let role = roleRef as? String {
                    isEditable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
                }
            }
            
            // Method 3: Check if we can perform editing actions
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
                    "isEditable": isEditable
                ]
            }
        }

        // Fallback to main window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
           let window = windowRef {
            let windowElement = window as! AXUIElement
            
            // Repeat the same checks for window element
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
                    "isEditable": isEditable
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
                        "isEditable": isEditable
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
                "isEditable": isEditable
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
            while let processedText = readLine() {
                self.copyToClipboard(processedText)
                self.performPaste()
            }
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func performPaste() {
        // Get the current frontmost application
        guard let currentApp = NSWorkspace.shared.frontmostApplication else {
            NSLog("Failed to get frontmost application")
            return
        }
        
        // Activate the app with a small delay to ensure focus
        currentApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        
        // Small delay to allow window activation to complete
        usleep(100000) // 100ms delay
        
        // Create the paste command
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        // Send Command-V keypress
        let keyVDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyVDown?.flags = .maskCommand
        let keyVUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyVUp?.flags = .maskCommand
        
        // Post the events with small delays between them
        keyVDown?.post(tap: loc)
        usleep(30000) // 30ms delay between key down and up
        keyVUp?.post(tap: loc)
        
        NSLog("Paste performed in \(currentApp.localizedName ?? "unknown app")")
    }

    func run() {
        CFRunLoopRun()
    }
}

let observer = SelectionObserver()
observer.run()