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
    // NSLog("Sending reset signal")
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
        // NSLog("Mouse down event")
        mouseIsDragging = false

    case .leftMouseDragged, .rightMouseDragged:
        // NSLog("Mouse drag event")
        mouseIsDragging = true

    case .leftMouseUp, .rightMouseUp:
        // NSLog("Mouse up event")
        mouseUpSelectionCheckTimer?.invalidate()
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let wasDrag = mouseIsDragging
        // NSLog("Setting timer for selection check (drag: \(wasDrag), clicks: \(clickCount))")
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { _ in
            // NSLog("Timer fired, calling selection handler")
            selectionChangedHandler?(wasDrag, clickCount)
        }
        mouseIsDragging = false

    case .mouseMoved:
        if popupShown, let popupPos = lastPopupPosition {
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 300 || dy > 300 {
                // NSLog("Mouse moved far from popup, sending reset")
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
        // NSLog("Initializing SelectionObserver")
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
            // NSLog("Selection handler called (drag: \(wasDrag), clicks: \(clickCount))")
            self?.handleSelectionOrDeselection(wasDrag: wasDrag, clickCount: clickCount)
        }
    }

    @objc func windowFocusChanged(_ notification: Notification? = nil) {
        // NSLog("Window focus changed")
        if popupShown {
            sendResetSignal()
        }
        ensureEventTapActive()
    }

    func ensureEventTapActive() {
        if let eventTap = eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            // NSLog("Re-enabling event tap")
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    static func currentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            // NSLog("No frontmost application")
            return nil
        }
        
        // NSLog("Checking selection for app: \(frontApp.localizedName ?? "unknown")")
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var isEditable = false

        // First try to get focused element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
            let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            
            // Check if element is editable
            var editableRef: CFTypeRef?
            let editableAttribute = "AXEditable" as CFString
            if AXUIElementCopyAttributeValue(element, editableAttribute, &editableRef) == .success {
                isEditable = editableRef as? Bool ?? false
            }
            
            // Get selected text if available
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

        // Fallback to main window if focused element didn't work
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef {
            let windowElement = window as! AXUIElement
            
            // Check if window is editable
            var editableRef: CFTypeRef?
            let editableAttribute = "AXEditable" as CFString
            if AXUIElementCopyAttributeValue(windowElement, editableAttribute, &editableRef) == .success {
                isEditable = editableRef as? Bool ?? false
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
        
        // NSLog("No selection found in focused element or main window")
        return nil
    }

    func getSelectedTextViaClipboard() -> String? {
        guard !isProcessingClipboard else {
            // NSLog("Already processing clipboard, skipping")
            return nil
        }
        
        isProcessingClipboard = true
        defer { isProcessingClipboard = false }
        
        // NSLog("Starting clipboard method")
        
        // Temporarily disable event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        
        defer {
            // Re-enable event tap when done
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
            // NSLog("Clipboard attempt \(attempt)")
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
                        // NSLog("Clipboard success on attempt \(attempt): '\(copiedText)'")
                        
                        pasteboard.clearContents()
                        if let originalContent = originalContent {
                            pasteboard.setString(originalContent, forType: .string)
                        }
                        
                        return copiedText
                    }
                }
                usleep(10000)
            }
            
            // NSLog("Clipboard attempt \(attempt) failed")
            
            if attempt < 3 {
                usleep(100000)
            }
        }
        
        // NSLog("All clipboard attempts failed")
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
        
        // Define all cases where we should try clipboard
        var currentCase = "None"
        let shouldTryClipboard: Bool
        
        // First check for exact matches
        if selectedText.isEmpty {
            currentCase = "Empty string"
            shouldTryClipboard = false
        } else if selectedText == " " {
            currentCase = "Single space"
            shouldTryClipboard = true
        } 
        // Then check for other whitespace cases
        else if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentCase = "Whitespace string"
            shouldTryClipboard = true
        } 
        // Default case
        else {
            currentCase = "Non-whitespace text"
            shouldTryClipboard = false
        }
        
        let finalShouldTry = shouldTryClipboard && (wasDrag || clickCount == 2 || clickCount == 3)
        // NSLog("Selected text--->: '\(selectedText)' Current case: \(currentCase). Should try clipboard: \(finalShouldTry)")

        if finalShouldTry {
            // NSLog("Trying clipboard method for case: \(currentCase)")
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
        
        // For all other cases, use the original selection
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if (wasDrag || clickCount == 2 || clickCount == 3), hasMeaningfulText, selectedText != lastSelectionText {
            NSLog("Sending selection")
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
            // NSLog("Sending reset due to empty or whitespace-only selection")
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
            // NSLog("Mouse event tap created successfully")
        } else {
            // NSLog("Failed to create event tap for mouse events.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.setupMouseEventListener()
            }
        }
    }

    func listenForProcessedText() {
        DispatchQueue.global().async {
            while let processedText = readLine() {
                // NSLog("Received processed text")
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
        // NSLog("Performing paste")
        let src = CGEventSource(stateID: .hidSystemState)
        let keyVDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyVDown?.flags = .maskCommand
        let keyVUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyVUp?.flags = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        keyVDown?.post(tap: loc)
        keyVUp?.post(tap: loc)
    }

    func run() {
        // NSLog("Starting observer run loop")
        CFRunLoopRun()
    }
}

let observer = SelectionObserver()
observer.run()