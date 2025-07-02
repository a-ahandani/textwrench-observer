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
        AXObserverCreate(pid, { _, _, _, _ in
            SelectionObserver.reportSelection()
        }, &observer)

        guard let observer = observer else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let appElement = AXUIElementCreateApplication(pid)
        var focusedElementRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        if let focusedElement = focusedElementRef {
            AXObserverAddNotification(observer, focusedElement as! AXUIElement, kAXSelectedTextChangedNotification as CFString, nil)
            AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, nil)
        }

        SelectionObserver.reportSelection()
    }

    static func currentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElement = focusedElementRef else { return nil }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let axValue = selectedRangeRef, AXValueGetType(axValue as! AXValue) == .cfRange else { return nil }

        var selectedRange = CFRange()
        AXValueGetValue(axValue as! AXValue, .cfRange, &selectedRange)

        var fullTextRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXValueAttribute as CFString, &fullTextRef) == .success,
              let fullText = fullTextRef as? String else { return nil }

        guard selectedRange.location != kCFNotFound, selectedRange.length > 0 else { return nil }

        let start = fullText.index(fullText.startIndex, offsetBy: selectedRange.location)
        let end = fullText.index(start, offsetBy: selectedRange.length)
        let selectedText = String(fullText[start..<end])

        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionAXValue = positionRef else { return nil }

        var position = CGPoint.zero
        AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &position)

        return [
            "text": selectedText,
            "position": ["x": position.x, "y": position.y]
        ]
    }

    static func reportSelection() {
        if let selection = currentSelection(),
           let jsonData = try? JSONSerialization.data(withJSONObject: selection),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString, terminator: "\n")
            fflush(stdout)
        }
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let selection = SelectionObserver.currentSelection(),
               let selectedText = selection["text"] as? String,
               selectedText != self.lastSelection {
                self.lastSelection = selectedText
                SelectionObserver.reportSelection()
            }
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
