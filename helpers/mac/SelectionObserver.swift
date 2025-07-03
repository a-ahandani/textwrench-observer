#!/usr/bin/env swift

import Cocoa
import ApplicationServices

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

        // Use deduplication logic on startup, too
        self.triggerIfSelectionChanged()
    }

static func currentSelection() -> [String: Any]? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontApp.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    
    // Helper to check if element is editable (moved inside the function)
    func isElementEditable(_ element: AXUIElement) -> Bool {
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success,
           let isEditable = editableRef as? Bool {
            return isEditable
        }
        
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let editableRoles = ["AXTextArea", "AXTextField", "AXTextField"]
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
    
    // Helper to get bounds of an element
    func getBounds(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
           let positionValue = positionRef,
           AXValueGetType(positionValue as! AXValue) == .cgPoint {
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        }
        
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeValue = sizeRef,
           AXValueGetType(sizeValue as! AXValue) == .cgSize {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        
        return CGRect(origin: position, size: size)
    }
    
    // First try the focused element approach (editable text)
    var focusedElementRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
       let focusedElement = focusedElementRef {
        
        let element = focusedElement as! AXUIElement
        let isEditable = isElementEditable(element)
        
        // Try to get selected text
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            
            // Get element bounds
            var position = CGPoint.zero
            if let bounds = getBounds(element) {
                position = bounds.origin
            }
            
            return [
                "text": selectedText,
                "position": ["x": position.x, "y": position.y],
                "editable": isEditable
            ]
        }
    }
    
    // For non-editable text (like in browsers)
    var windowRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
       let window = windowRef {
        
        let windowElement = window as! AXUIElement
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            
            // Get the selected text range
            var selectedRangeRef: CFTypeRef?
            var selectedRange = CFRange()
            if AXUIElementCopyAttributeValue(windowElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
               let rangeValue = selectedRangeRef,
               AXValueGetType(rangeValue as! AXValue) == .cfRange {
                AXValueGetValue(rangeValue as! AXValue, .cfRange, &selectedRange)
            }
            
            // Get window position to adjust coordinates
            var windowPosition = CGPoint.zero
            if let windowBounds = getBounds(windowElement) {
                windowPosition = windowBounds.origin
            }
            
            // Estimate position based on line height (since we can't get exact bounds)
            let lineHeight: CGFloat = 20 // Approximate line height
            let estimatedY = windowPosition.y + lineHeight
            
            return [
                "text": selectedText,
                "position": ["x": windowPosition.x, "y": estimatedY],
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
