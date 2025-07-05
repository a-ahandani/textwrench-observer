#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// Track popup state
var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""

// Keep track of the last signal sent (as a string, to compare easily)
var lastSentSignal: String?

// Declare a global handler to call when selection should be checked
var selectionChangedHandler: (() -> Void)?

// Utility: Get the mouse position in top-left screen coordinates
func currentMouseTopLeftPosition() -> (x: CGFloat, y: CGFloat) {
    let mouseLocation = NSEvent.mouseLocation
    // Find the screen under the mouse, fallback to main
    let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
    guard let screenFrame = screen?.frame else {
        // Fallback: Just flip y using main screen height
        let h = NSScreen.main?.frame.height ?? 0
        return (mouseLocation.x, h - mouseLocation.y)
    }
    // In macOS, Y increases upwards, so top-left is (x, screenHeight - (y - screenY))
    let flippedY = screenFrame.origin.y + screenFrame.size.height - mouseLocation.y
    return (mouseLocation.x, flippedY)
}

// Helper to send signals only if changed
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

// Top-level C callback for event tap
private func globalMouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pos = event.location
    // Flip Y for popup compatibility
    let mousePos = currentMouseTopLeftPosition()

    if type == .leftMouseUp || type == .rightMouseUp {
        // On mouseup, check for a selection change
        selectionChangedHandler?()
    }

    if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
        // Only if popup is shown
        if popupShown, let popupPos = lastPopupPosition {
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 100 || dy > 100 {
                // Emit close signal, only once and only if different
                let empty: [String: Any] = [
                    "text": "",
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
                sendSignalIfChanged(empty)
                popupShown = false
                lastPopupPosition = nil
                lastSelectionText = ""
            }
        }
    }

    return Unmanaged.passRetained(event)
}

// Mouse event tap setup for mousemove and mouseup
func startMouseEventListener(selectionChanged: @escaping () -> Void) {
    selectionChangedHandler = selectionChanged

    let mouseEventMask =
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.rightMouseUp.rawValue) |
        (1 << CGEventType.mouseMoved.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.rightMouseDragged.rawValue)

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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(focusedAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        setupObserverForFrontmostApp()
        startPolling()

        // Start mouse event listener (pass in triggerIfSelectionChanged)
        startMouseEventListener { [weak self] in
            self?.triggerIfSelectionChanged()
        }
        listenForProcessedText()
    }

    @objc func focusedAppChanged(_ notification: Notification? = nil) {
        setupObserverForFrontmostApp()
    }

    func setupObserverForFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        var observer: AXObserver?
        let observerCallback: AXObserverCallback = { observer, element, notification, refcon in
            let instance = Unmanaged<SelectionObserver>.fromOpaque(refcon!).takeUnretainedValue()
            instance.triggerIfSelectionChanged()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverCreate(pid, observerCallback, &observer)

        guard let observer = observer else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let appElement = AXUIElementCreateApplication(pid)
        var focusedElementRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        if let focusedElement = focusedElementRef {
            AXObserverAddNotification(observer, focusedElement as! AXUIElement, kAXSelectedTextChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        }
        self.triggerIfSelectionChanged()
    }

    static func currentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Helper to check if element is editable
        func isElementEditable(_ element: AXUIElement) -> Bool {
            var editableRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success,
                let isEditable = editableRef as? Bool {
                return isEditable
            }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef) == .success,
                let role = roleRef as? String {
                let editableRoles = ["AXTextArea", "AXTextField"]
                if editableRoles.contains(role) {
                    return true
                }
            }
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable) == .success {
                return settable.boolValue
            }
            return false
        }

        // Try focused element first (editable text)
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
            let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            let isEditable = isElementEditable(element)

            // Try to get selected text
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
                let selectedText = selectedTextRef as? String {
                // Get mouse location for popup (flipped Y)
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "editable": isEditable
                ]
            }
        }

        // Try main window for non-editable text
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
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "editable": false
                ]
            }
        }

        return nil
    }

    func triggerIfSelectionChanged() {
        if let selection = SelectionObserver.currentSelection(),
            let selectedText = selection["text"] as? String {
            if !selectedText.isEmpty {
                // Only emit if text actually changed (and is not empty)
                if selectedText != lastSelectionText {
                    lastSelectionText = selectedText
                    // Get position
                    if let position = selection["position"] as? [String: Any],
                        let x = position["x"] as? CGFloat,
                        let y = position["y"] as? CGFloat {
                        lastPopupPosition = CGPoint(x: x, y: y)
                    }
                    popupShown = true

                    // Print popup signal only if different
                    sendSignalIfChanged(selection)
                }
            } else {
                // Text is empty, i.e. deselected
                if popupShown {
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
            }
        } else {
            // No selection, treat as deselection
            if popupShown {
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
        }
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // Polling for completeness; main logic is in event tap
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
