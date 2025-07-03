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
    
    // First try the focused element approach (works for editable text)
    var focusedElementRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
       let focusedElement = focusedElementRef {
        
        // Try to get selected text directly
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            
            // Get position if available
            var positionRef: CFTypeRef?
            var position: CGPoint = .zero
            if AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
               let positionAXValue = positionRef,
               AXValueGetType(positionAXValue as! AXValue) == .cgPoint {
                AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &position)
            }
            
            return [
                "text": selectedText,
                "position": ["x": position.x, "y": position.y]
            ]
        }
    }
    
    // If focused element approach failed, try the main window approach (for non-editable text)
    var windowRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef) == .success,
       let window = windowRef {
        
        // Try to get selected text from the window
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            
            // Get position if available
            var positionRef: CFTypeRef?
            var position: CGPoint = .zero
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
               let positionAXValue = positionRef,
               AXValueGetType(positionAXValue as! AXValue) == .cgPoint {
                AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &position)
            }
            
            return [
                "text": selectedText,
                "position": ["x": position.x, "y": position.y]
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
