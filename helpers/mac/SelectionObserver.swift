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

// === Fallback (Clipboard Copy) Strategy ===
func performCmdC() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyCDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) // kVK_ANSI_C = 8
    keyCDown?.flags = .maskCommand
    let keyCUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
    keyCUp?.flags = .maskCommand
    let loc = CGEventTapLocation.cghidEventTap
    keyCDown?.post(tap: loc)
    keyCUp?.post(tap: loc)
}

func readClipboard() -> String {
    let pb = NSPasteboard.general
    if let contents = pb.string(forType: .string) {
        return contents
    }
    return ""
}

func tryClipboardSelection(completion: @escaping (_ selectedText: String?) -> Void) {
    performCmdC()
    // Wait for clipboard to update
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { // 100ms delay
        let copied = readClipboard()
        if !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && copied != " " {
            completion(copied)
        } else {
            completion(nil)
        }
    }
}


// === MAIN OBSERVER ===

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

    // This method now handles both accessibility and fallback strategies.
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

    /// Main handler: if accessibility returns " ", try fallback (cmd+c)
    func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int) {
        let selection = SelectionObserver.currentSelection()
        let selectedText = selection?["text"] as? String ?? ""

        // If selection is a single space, accessibility failed (Google Docs etc)
        if (wasDrag || clickCount == 2 || clickCount == 3),
           selectedText == " " {

            // Fallback strategy
                tryClipboardSelection { clipboardText in
                    if let clipboardText = clipboardText,
                        !clipboardText.isEmpty,
                        clipboardText != lastSelectionText {

                    lastSelectionText = clipboardText
                    if let position = selection?["position"] as? [String: Any],
                       let x = position["x"] as? CGFloat,
                       let y = position["y"] as? CGFloat {
                        lastPopupPosition = CGPoint(x: x, y: y)
                    }
                    popupShown = true
                    sendSignalIfChanged([
                        "text": clipboardText,
                        "position": selection?["position"] ?? currentMouseTopLeftPosition()
                    ])
                }
            }
            return
        }

        // Only send selection if actual drag, or double/triple click, and not empty, not a space
        if (wasDrag || clickCount == 2 || clickCount == 3),
            !selectedText.isEmpty,
            selectedText != " ",
            selectedText != lastSelectionText {

            lastSelectionText = selectedText
            if let position = selection?["position"] as? [String: Any],
               let x = position["x"] as? CGFloat,
               let y = position["y"] as? CGFloat {
                lastPopupPosition = CGPoint(x: x, y: y)
            }
            popupShown = true
            sendSignalIfChanged(selection!)
        }
        // Send deselect if selection is cleared and popup was up
        else if selectedText.isEmpty, popupShown {
            sendResetSignal()
        }
        // Else: nothing to do (no selection, and nothing was shown, or not a selection gesture)
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
