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
            let pos = event.location
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

/// Recursively search AXValue/AXDescription/AXTitle in the accessibility tree
func getSelectedTextFromAccessibilityTree(_ element: AXUIElement, depth: Int = 0) -> String? {
    // AXValue
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
       let valueStr = value as? String, !valueStr.isEmpty {
        return valueStr
    }
    // AXDescription
    var desc: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc) == .success,
       let descStr = desc as? String, !descStr.isEmpty {
        return descStr
    }
    // AXTitle
    var title: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
       let titleStr = title as? String, !titleStr.isEmpty {
        return titleStr
    }
    // Children
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let arr = children as? [AXUIElement], depth < 6 {
        for child in arr {
            if let found = getSelectedTextFromAccessibilityTree(child, depth: depth + 1) {
                return found
            }
        }
    }
    return nil
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

        // AXSelectedText on focused UI element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success {
            let element = focusedElementRef as! AXUIElement
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String, !selectedText.isEmpty {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
            // Try recursively
            if let found = getSelectedTextFromAccessibilityTree(element), !found.isEmpty {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": found,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
        }

        // AXSelectedText on window element as fallback
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success {
            let windowElement = windowRef as! AXUIElement
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
               let selectedText = selectedTextRef as? String, !selectedText.isEmpty {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
            // Try recursively
            if let found = getSelectedTextFromAccessibilityTree(windowElement), !found.isEmpty {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": found,
                    "position": ["x": mousePos.x, "y": mousePos.y]
                ]
            }
        }
        return nil
    }

    /// Only send selection if drag, or double/triple click (clickCount 2 or 3)
    /// Never send on single click, even if there is a selection.
    /// Always send deselect on clear, or on window focus change.
    func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int) {
        let selection = SelectionObserver.currentSelection()
        let selectedText = selection?["text"] as? String ?? ""

        if (wasDrag || clickCount == 2 || clickCount == 3), !selectedText.isEmpty, selectedText != lastSelectionText {
            lastSelectionText = selectedText
            if let position = selection?["position"] as? [String: Any],
               let x = position["x"] as? CGFloat,
               let y = position["y"] as? CGFloat {
                lastPopupPosition = CGPoint(x: x, y: y)
            }
            popupShown = true
            sendSignalIfChanged(selection!)
        }
        else if selectedText.isEmpty, popupShown {
            sendResetSignal()
        }
        // Else: nothing to do
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
