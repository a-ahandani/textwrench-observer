#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// MARK: - Constants
let kAXEditableAttribute = "AXEditable"

// MARK: - Web App Constants
private let webAppBundleIDs = [
    "com.google.Chrome",
    "com.apple.Safari",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.operasoftware.Opera"
]

// MARK: - Google Docs Constants
private let googleDocsDomains = [
    "docs.google.com",
    "drive.google.com",
    "Google Docs",
    "Google Drive"
]

// MARK: - Text Editor Bundle IDs
private let textEditorBundleIDs = [
    "com.apple.TextEdit",
    "com.apple.Notes",
    "com.microsoft.VSCode",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "com.jetbrains.AppCode",
    "com.jetbrains.CLion",
    "com.jetbrains.datagrip",
    "com.jetbrains.goland",
    "com.jetbrains.PhpStorm",
    "com.jetbrains.pycharm",
    "com.jetbrains.rider",
    "com.jetbrains.rubymine",
    "com.jetbrains.WebStorm",
    "com.panic.Nova",
    "com.coteditor.CotEditor",
    "org.vim.MacVim",
    "com.macromates.TextMate",
    "com.barebones.bbedit",
    "com.activestate.komodo-ide",
    "com.ultraedit.UltraEdit",
    "com.codelobster.IDEDeveloper"
]

// MARK: - Modifier State Tracking
struct ModifierFlags: OptionSet {
    let rawValue: Int
    static let shift     = ModifierFlags(rawValue: 1 << 0)
    static let control   = ModifierFlags(rawValue: 1 << 1)
    static let option    = ModifierFlags(rawValue: 1 << 2)
    static let command   = ModifierFlags(rawValue: 1 << 3)
    init(rawValue: Int) { self.rawValue = rawValue }
    init(cgEventFlags: CGEventFlags) {
        var flags = ModifierFlags()
        if cgEventFlags.contains(.maskShift)    { flags.insert(.shift) }
        if cgEventFlags.contains(.maskControl)  { flags.insert(.control) }
        if cgEventFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgEventFlags.contains(.maskCommand)   { flags.insert(.command) }
        self = flags
    }
}

class ModifierState {
    private(set) var currentFlags: ModifierFlags = []
    private let debounceInterval: TimeInterval = 0.05
    private var debounceTimer: Timer?
    func update(with event: CGEvent) {
        let newFlags = ModifierFlags(cgEventFlags: event.flags)
        if [.leftMouseDown].contains(event.type) {
            currentFlags = newFlags
            return
        }
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.currentFlags = newFlags
        }
    }
    func lockCurrentState() -> ModifierFlags {
        debounceTimer?.invalidate()
        return currentFlags
    }
}

// MARK: - Main Implementation
class SelectionObserver {
    private var lastPopupPosition: CGPoint?
    private var popupShown: Bool = false
    private var lastSelectionText: String = ""
    private var lastSentSignal: String?
    private var mouseIsDragging = false
    private var lastWindowInfo: [String: Any]?
    let modifierState = ModifierState()
    private var pendingSelectionText: String?
    private var pendingSelectionTimer: Timer?
    private var initialMousePosition: CGPoint?
    private let positionThreshold: CGFloat = 50.0
    private let timeThreshold: TimeInterval = 0.3
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseUpSelectionCheckTimer: Timer?
    private var isProcessingClipboard = false
    private var activationObserver: NSObjectProtocol?

    init() {
        setupMouseEventListener()
        setupApplicationNotifications()
        listenForProcessedText()
    }

    deinit {
        invalidateTimers()
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    private func setupApplicationNotifications() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.windowFocusChanged()
        }
    }

    private func invalidateTimers() {
        mouseUpSelectionCheckTimer?.invalidate()
        pendingSelectionTimer?.invalidate()
    }

    private func isGoogleDocsContext(bundleID: String?, windowTitle: String?) -> Bool {
        guard let bundleID = bundleID, webAppBundleIDs.contains(bundleID), let title = windowTitle else { return false }
        return googleDocsDomains.contains { title.localizedCaseInsensitiveContains($0) }
    }

    private func isTextEditorContext(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return textEditorBundleIDs.contains(bundleID)
    }

    private func isWebBrowser(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return webAppBundleIDs.contains(bundleID)
    }

    private func hasEditableFocus(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedElement = getFocusedElement(appElement) else { return false }
        var isEditable: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXEditableAttribute as CFString, &isEditable) == .success {
            return isEditable as? Bool ?? false
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role) == .success, let roleValue = role as? String {
            let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, "AXContentGroup", "AXDocument", "AXWebArea"]
            if roleValue == "AXWebArea" { return isWebContentEditable(focusedElement) }
            return editableRoles.contains(roleValue)
        }
        return false
    }

    private func isWebContentEditable(_ element: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let childrenArray = children as? [AXUIElement] else { return false }
        for child in childrenArray {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success, let roleValue = role as? String, roleValue == kAXTextAreaRole || roleValue == kAXTextFieldRole {
                var editable: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXEditableAttribute as CFString, &editable) == .success {
                    return editable as? Bool ?? false
                }
            }
        }
        return false
    }

    private func getFocusedElement(_ appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success, let element = focusedElement, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func getMainWindow(_ appElement: AXUIElement) -> AXUIElement? {
        var mainWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow) == .success, let element = mainWindow, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func getWindowForElement(_ element: AXUIElement) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let element = window, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func getWindowTitle(_ window: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private func setupMouseEventListener() {
        let mask = (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        let observerRef = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            let observer = Unmanaged<SelectionObserver>.fromOpaque(refcon!).takeUnretainedValue()
            return observer.handleMouseEvent(proxy: proxy, type: type, event: event)
        }, userInfo: observerRef)
        if let eventTap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            print("Error: Failed to create event tap. Accessibility permissions may be required.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.setupMouseEventListener() }
        }
    }

    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        modifierState.update(with: event)
        switch type {
        case .leftMouseDown:   mouseIsDragging = false
        case .leftMouseDragged: mouseIsDragging = true
        case .leftMouseUp:     handleMouseUp(event: event)
        case .mouseMoved:      handleMouseMoved(event: event)
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleMouseUp(event: CGEvent) {
        mouseIsDragging = false
        initialMousePosition = nil
        let modifiers = modifierState.lockCurrentState()
        mouseUpSelectionCheckTimer?.invalidate()
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if let text = self.getSelectedText(), !text.isEmpty {
                self.pendingSelectionText = text
                self.pendingSelectionTimer?.invalidate()
                self.pendingSelectionTimer = Timer.scheduledTimer(withTimeInterval: self.timeThreshold, repeats: false) { [weak self] _ in
                    self?.handlePendingSelection(modifiers: modifiers)
                }
                self.initialMousePosition = event.location
            }
        }
    }

    private func handleMouseMoved(event: CGEvent) {
        guard let initialPosition = initialMousePosition, let _ = pendingSelectionText else { return }
        let dx = event.location.x - initialPosition.x
        let dy = event.location.y - initialPosition.y
        if sqrt(dx*dx + dy*dy) > positionThreshold {
            pendingSelectionText = nil
            pendingSelectionTimer?.invalidate()
        }
    }

    private func handlePendingSelection(modifiers: ModifierFlags) {
        guard let text = pendingSelectionText else { return }
        pendingSelectionText = nil
        if text != lastSelectionText {
            lastSelectionText = text
            sendSelection(text: text, modifiers: modifiers)
        }
    }

    private func getSelectedText() -> String? {
        if isProcessingClipboard { return nil }
        isProcessingClipboard = true
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems
        pasteboard.clearContents()
        simulateCopyCommand()
        usleep(100_000)
        let copiedText = pasteboard.string(forType: .string)
        if let items = savedItems {
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
        isProcessingClipboard = false
        return copiedText
    }

    private func simulateCopyCommand() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand
        let cUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        cmdUp?.flags = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        cmdDown?.post(tap: loc)
        cDown?.post(tap: loc)
        cUp?.post(tap: loc)
        cmdUp?.post(tap: loc)
    }

    private func sendSelection(text: String, modifiers: ModifierFlags) {
        print("Selection: \(text)")
    }

    private func listenForProcessedText() {}
    private func windowFocusChanged() {}
    func run() { CFRunLoopRun() }
}

let observer = SelectionObserver()
observer.run()
