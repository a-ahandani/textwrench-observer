#!/usr/bin/env swift

import Cocoa
import ApplicationServices

var lastPopupPosition: CGPoint? = nil
var popupShown: Bool = false
var lastSelectionText: String = ""
var lastSentSignal: String?
var selectionChangedHandler: (() -> Void)?
var mouseUpSelectionCheckTimer: Timer? // For delay after mouse up

// --- New: Global reset timer for debounced reset signal
var resetSignalTimer: Timer?

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

// --- New: Delayed reset signal sender with debounce
func sendResetSignalWithDelay(_ delay: TimeInterval = 0.3) {
    resetSignalTimer?.invalidate()
    resetSignalTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
        sendResetSignal()
    }
}

// --- Modified: sendResetSignal now private/internal
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

// --- Keyboard event handling ---
var lastSelectionEditable: Bool = false
var suppressNextKeyDeselect: Bool = false

private func globalKeyboardEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Only keyDown (ignore keyUp)
    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    // If there is a selection and it's in an editable field, and popup is shown, send deselect signal
    if popupShown, !lastSelectionText.isEmpty, lastSelectionEditable {
        sendResetSignalWithDelay()
        suppressNextKeyDeselect = true
    }
    return Unmanaged.passRetained(event)
}

func startKeyboardEventListener() {
    let keyEventMask = (1 << CGEventType.keyDown.rawValue)

    let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(keyEventMask),
        callback: globalKeyboardEventCallback,
        userInfo: nil
    )
    if let eventTap = eventTap {
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    } else {
        print("Failed to create event tap for keyboard events.")
    }
}

// --- Mouse event handling (unchanged except for reset signal) ---
private func globalMouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pos = event.location

    if type == .leftMouseUp || type == .rightMouseUp {
        // Delay the selection check to let macOS update selection state
        mouseUpSelectionCheckTimer?.invalidate()
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { _ in
            selectionChangedHandler?()
        }
    }

    if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
        if popupShown, let popupPos = lastPopupPosition {
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 400 || dy > 400 {
                sendResetSignalWithDelay()
            }
        }
    }

    return Unmanaged.passRetained(event)
}

func startMouseEventListener(selectionChanged: @escaping () -> Void) {
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

// --- Selection Observer (changed: records if selection was editable) ---
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

        startMouseEventListener { [weak self] in
            self?.triggerIfSelectionChanged()
        }
        startKeyboardEventListener()
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

        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
            let focusedElement = focusedElementRef {
            let element = focusedElement as! AXUIElement
            let isEditable = isElementEditable(element)
            var selectedTextRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
                let selectedText = selectedTextRef as? String {
                let mousePos = currentMouseTopLeftPosition()
                return [
                    "text": selectedText,
                    "position": ["x": mousePos.x, "y": mousePos.y],
                    "editable": isEditable
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
            let editable = (selection["editable"] as? Bool) ?? false
            lastSelectionEditable = editable
            if !selectedText.isEmpty {
                if selectedText != lastSelectionText {
                    lastSelectionText = selectedText
                    if let position = selection["position"] as? [String: Any],
                        let x = position["x"] as? CGFloat,
                        let y = position["y"] as? CGFloat {
                        lastPopupPosition = CGPoint(x: x, y: y)
                    }
                    popupShown = true
                    sendSignalIfChanged(selection)
                    suppressNextKeyDeselect = false // allow keyboard handler again
                }
            } else {
                if popupShown {
                    sendResetSignalWithDelay()
                    suppressNextKeyDeselect = false
                }
            }
        } else {
            if popupShown {
                sendResetSignalWithDelay()
                suppressNextKeyDeselect = false
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
