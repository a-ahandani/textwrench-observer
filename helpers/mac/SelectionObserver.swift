#!/usr/bin/env swift

import Cocoa
import ApplicationServices

var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""
var lastSentSignal: String?
var selectionChangedHandler: ((Bool) -> Void)?
var mouseUpSelectionCheckTimer: Timer?
var mouseIsDragging = false
var pendingSelectionWasDrag = false
var pendingSelectionIsDoubleOrTripleClick = false
var lastMouseClickCount: Int = 0

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
        pendingSelectionWasDrag = false
        pendingSelectionIsDoubleOrTripleClick = false
        lastMouseClickCount = Int(event.getIntegerValueField(.mouseEventClickState))

    case .leftMouseDragged, .rightMouseDragged:
        mouseIsDragging = true

    case .leftMouseUp, .rightMouseUp:
        mouseUpSelectionCheckTimer?.invalidate()
        let wasDrag = mouseIsDragging
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        // If double or triple click, treat as a selection gesture.
        let isDoubleOrTripleClick = (clickCount == 2 || clickCount == 3)
        pendingSelectionWasDrag = wasDrag
        pendingSelectionIsDoubleOrTripleClick = isDoubleOrTripleClick

        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { _ in
            selectionChangedHandler?(pendingSelectionWasDrag || pendingSelectionIsDoubleOrTripleClick)
        }
        mouseIsDragging = false
        pendingSelectionWasDrag = false
        pendingSelectionIsDoubleOrTripleClick = false

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

func startMouseEventListener(selectionChanged: @escaping (Bool) -> Void) {
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
        startMouseEventListener { [weak self] isSelectionGesture in
            self?.triggerIfSelectionChanged(selectionGesture: isSelectionGesture)
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

    // selectionGesture: true for drag, double, or triple click; false for normal click
    func triggerIfSelectionChanged(selectionGesture: Bool) {
        let selection = SelectionObserver.currentSelection()
        let selectedText = selection?["text"] as? String ?? ""

        if selectionGesture {
            // Send selection if text is selected and changed
            if !selectedText.isEmpty, selectedText != lastSelectionText {
                lastSelectionText = selectedText
                if let position = selection?["position"] as? [String: Any],
                   let x = position["x"] as? CGFloat,
                   let y = position["y"] as? CGFloat {
                    lastPopupPosition = CGPoint(x: x, y: y)
                }
                popupShown = true
                sendSignalIfChanged(selection!)
            }
            // If after a gesture, selection is empty, clear any shown popup
            else if selectedText.isEmpty, popupShown {
                sendResetSignal()
            }
        } else {
            // On plain click, if selection is cleared, send reset
            if selectedText.isEmpty, popupShown {
                sendResetSignal()
            }
            // If selection remains and this was just a click, do nothing (don't send selected text)
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
