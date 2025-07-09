#!/usr/bin/env swift

import Cocoa
import ApplicationServices

var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""
var lastSentSignal: String?
var selectionChangedHandler: ((Bool, Int) -> Void)?
var mouseUpSelectionCheckTimer: Timer?
var mouseIsDragging = false

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

    let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mouseEventMask),
        callback: globalMouseEventCallback,
        userInfo: nil
    )

    if let eventTap = eventTap {
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    } else {
        print("Failed to create event tap for mouse events.")
    }
}

class SelectionObserver {
    private var timer: Timer?

    init() {
        startMouseEventListener { [weak self] wasDrag, clickCount in
            self?.handleSelectionOrDeselection(wasDrag: wasDrag, clickCount: clickCount)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowFocusChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        listenForProcessedText()
    }

    @objc func windowFocusChanged(_ notification: Notification? = nil) {
        if popupShown {
            sendResetSignal()
        }
    }

    static func currentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
            let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
                let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
        }

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef {
            let windowElement = window as! AXUIElement
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
                let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
        }
        return nil
    }

    static func getSelectedTextViaClipboard() -> String? {
        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount
        
        // Ensure we have a clean state for the operation
        defer {
            // Always restore original clipboard content, even if we fail
            pasteboard.clearContents()
            if let originalContent = originalContent {
                pasteboard.setString(originalContent, forType: .string)
            }
        }
        
        // Clear clipboard and wait for it to be cleared
        pasteboard.clearContents()
        
        // Try to ensure focus is on the current app/window
        if let currentApp = NSWorkspace.shared.frontmostApplication {
            currentApp.activate(options: [])
        }
        
        // Small delay to ensure focus
        usleep(50000) // 50ms
        
        // Send Cmd+C to copy selection - try multiple times if needed
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        // Try sending the copy command
        for attempt in 1...3 {
            NSLog("Clipboard method attempt \(attempt)")
            
            // Create and send the copy command
            if let keyCDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
               let keyCUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) {
                
                keyCDown.flags = .maskCommand
                keyCUp.flags = .maskCommand
                
                keyCDown.post(tap: loc)
                usleep(20000) // 20ms between key down and up
                keyCUp.post(tap: loc)
                
                // Wait for clipboard to change (with timeout)
                let startTime = CFAbsoluteTimeGetCurrent()
                let timeout: CFTimeInterval = 0.3 // 300ms timeout per attempt
                
                while CFAbsoluteTimeGetCurrent() - startTime < timeout {
                    if pasteboard.changeCount > originalChangeCount {
                        if let copiedText = pasteboard.string(forType: .string) {
                            NSLog("Clipboard method got text on attempt \(attempt): '\(copiedText.prefix(50))...'")
                            return copiedText
                        }
                    }
                    usleep(10000) // 10ms
                }
            }
            
            NSLog("Clipboard method attempt \(attempt) failed")
            
            // Small delay between attempts
            if attempt < 3 {
                usleep(100000) // 100ms
            }
        }
        
        NSLog("Clipboard method failed after all attempts")
        return nil
    }

    /// Only send selection if drag, or double/triple click (clickCount 2 or 3)
    /// Never send on single click, even if there is a selection.
    /// Always send deselect on clear, or on window focus change.
    func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int) {
        // This method is called for each selection attempt and should work independently
        // even if previous attempts failed
        
        let selection = SelectionObserver.currentSelection()
        var selectedText = selection?["text"] as? String ?? ""
        
        // Debug: print accessibility API result
        if !selectedText.isEmpty {
            NSLog("Accessibility API got text: '\(selectedText.prefix(50))...'")
        } else {
            NSLog("Accessibility API got no text")
        }

        // Check if text is effectively empty (empty or whitespace only)
        let isEffectivelyEmpty = selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Special fix: if selection is effectively empty but we have a selection gesture, try clipboard method
        if isEffectivelyEmpty && (wasDrag || clickCount == 2 || clickCount == 3) {
            NSLog("Trying clipboard method due to empty/whitespace accessibility result")
            
            // Try clipboard method - this will return nil if it fails, but won't break future attempts
            if let clipboardText = SelectionObserver.getSelectedTextViaClipboard() {
                let trimmedClipboardText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedClipboardText.isEmpty {
                    selectedText = clipboardText
                    NSLog("Clipboard method succeeded, got: '\(selectedText.prefix(50))...'")
                } else {
                    NSLog("Clipboard method returned empty/whitespace text")
                }
            } else {
                NSLog("Clipboard method returned nil - will try again on next selection")
            }
        }

        // Only send selection if actual drag, or double/triple click, and has meaningful text
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (wasDrag || clickCount == 2 || clickCount == 3), hasMeaningfulText, selectedText != lastSelectionText {
            NSLog("Sending selection: '\(selectedText.prefix(50))...'")
            lastSelectionText = selectedText
            let mousePos = currentMouseTopLeftPosition()
            lastPopupPosition = CGPoint(x: mousePos.x, y: mousePos.y)
            popupShown = true
            
            let selectionData: [String: Any] = [
                "text": selectedText,
                "position": ["x": mousePos.x, "y": mousePos.y]
            ]
            sendSignalIfChanged(selectionData)
        }
        // Send deselect if selection is cleared and popup was up
        else if !hasMeaningfulText, popupShown {
            NSLog("Sending reset signal")
            sendResetSignal()
        }
        // Else: nothing to do (no selection, and nothing was shown, or not a selection gesture)
        // The system is ready for the next selection attempt regardless of whether this one succeeded
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
        CFRunLoopRun()
    }
}

let observer = SelectionObserver()
observer.run()