#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// Store the last mouse up position globally
var lastMouseUpPosition: CGPoint = .zero

// Helper to start a global mouse-up event tap
func startMouseUpListener() {
    let eventMask = (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
    let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { _, type, event, _ in
            if type == .leftMouseUp || type == .rightMouseUp {
                lastMouseUpPosition = event.location
            }
            return Unmanaged.passRetained(event)
        },
        userInfo: nil
    )
    if let eventTap = eventTap {
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    } else {
        print("Failed to create event tap for mouse up events.")
    }
}

class SelectionObserver {
    private var timer: Timer?
    private var lastSelection: String = ""
    
    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(focusedAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        startMouseUpListener() // Start the mouse up event listener!
        setupObserverForFrontmostApp()
        startPolling()
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
                return [
                    "text": selectedText,
                    "position": ["x": lastMouseUpPosition.x, "y": lastMouseUpPosition.y],
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
                return [
                    "text": selectedText,
                    "position": ["x": lastMouseUpPosition.x, "y": lastMouseUpPosition.y],
                    "editable": false
                ]
            }
        }

        return nil
    }

    static func reportSelection() {
        if let selection = currentSelection(),
           let jsonData = try? JSONSerialization.data(withJSONObject: selection),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString, terminator: "\n")
            fflush(stdout)
        }
    }

    func triggerIfSelectionChanged() {
        if let selection = SelectionObserver.currentSelection(),
           let selectedText = selection["text"] as? String {
            if selectedText != self.lastSelection {
                self.lastSelection = selectedText
                SelectionObserver.reportSelection()
            }
        } else {
            // No selection found: check if we had a previous selection
            if !self.lastSelection.isEmpty {
                // Emit empty selection event
                let empty: [String: Any] = ["text": ""]
                if let jsonData = try? JSONSerialization.data(withJSONObject: empty),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString, terminator: "\n")
                    fflush(stdout)
                }
                self.lastSelection = "" // Reset lastSelection
            }
        }
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.triggerIfSelectionChanged()
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
