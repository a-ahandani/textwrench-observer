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
    "com.apple.TextEdit",          // TextEdit
    "com.apple.Notes",             // Notes
    "com.microsoft.VSCode",        // VS Code
    "com.sublimetext.4",           // Sublime Text
    "com.jetbrains.intellij",      // IntelliJ IDEA
    "com.jetbrains.AppCode",       // AppCode
    "com.jetbrains.CLion",         // CLion
    "com.jetbrains.datagrip",      // DataGrip
    "com.jetbrains.goland",        // GoLand
    "com.jetbrains.PhpStorm",      // PhpStorm
    "com.jetbrains.pycharm",       // PyCharm
    "com.jetbrains.rider",         // Rider
    "com.jetbrains.rubymine",      // RubyMine
    "com.jetbrains.WebStorm",      // WebStorm
    "com.panic.Nova",              // Nova
    "com.coteditor.CotEditor",     // CotEditor
    "org.vim.MacVim",              // MacVim
    "com.macromates.TextMate",     // TextMate
    "com.barebones.bbedit",        // BBEdit
    "com.activestate.komodo-ide",  // Komodo IDE
    "com.ultraedit.UltraEdit",     // UltraEdit
    "com.codelobster.IDEDeveloper" // Codelobster
]

// MARK: - Modifier State Tracking
struct ModifierFlags: OptionSet {
    let rawValue: Int
    
    static let shift     = ModifierFlags(rawValue: 1 << 0)
    static let control   = ModifierFlags(rawValue: 1 << 1)
    static let option    = ModifierFlags(rawValue: 1 << 2)
    static let command   = ModifierFlags(rawValue: 1 << 3)
    
    init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
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
    // State tracking
    private var lastPopupPosition: CGPoint?
    private var popupShown: Bool = false
    private var lastSelectionText: String = ""
    private var lastSentSignal: String?
    private var mouseIsDragging = false
    private var lastWindowInfo: [String: Any]?
    
    // Modifier state
    let modifierState = ModifierState()
    
    // Delayed selection handling
    private var pendingSelectionText: String?
    private var pendingSelectionTimer: Timer?
    private var initialMousePosition: CGPoint?
    private let positionThreshold: CGFloat = 50.0
    private let timeThreshold: TimeInterval = 0.3
    
    // Event handling
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseUpSelectionCheckTimer: Timer?
    private var isProcessingClipboard = false
    
    // MARK: - Initialization
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
    }
    
    // MARK: - Setup
    private func setupApplicationNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowFocusChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    private func invalidateTimers() {
        mouseUpSelectionCheckTimer?.invalidate()
        pendingSelectionTimer?.invalidate()
    }
    
    // MARK: - Context Detection
    private func isGoogleDocsContext(bundleID: String?, windowTitle: String?) -> Bool {
        guard let bundleID = bundleID, webAppBundleIDs.contains(bundleID),
              let title = windowTitle else { return false }
        
        return googleDocsDomains.contains { domain in
            title.localizedCaseInsensitiveContains(domain)
        }
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
        guard let focusedElement = getFocusedElement(appElement) else {
            return false
        }
        
        // Check AXEditable attribute
        var isEditable: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXEditableAttribute as CFString, &isEditable) == .success {
            return isEditable as? Bool ?? false
        }
        
        // Check for text input roles
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role) == .success {
            if let roleValue = role as? String {
                let editableRoles: Set<String> = [
                    kAXTextFieldRole,
                    kAXTextAreaRole,
                    "AXContentGroup",  // Apple Notes
                    "AXDocument",      // Some editors
                    "AXWebArea"        // Web content
                ]
                
                // Special case for web content: editable only if in input field
                if roleValue == "AXWebArea" {
                    return isWebContentEditable(focusedElement)
                }
                
                return editableRoles.contains(roleValue)
            }
        }
        
        return false
    }
    
    private func isWebContentEditable(_ element: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childrenArray = children as? [AXUIElement] else {
            return false
        }
        
        for child in childrenArray {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
               let roleValue = role as? String,
               roleValue == kAXTextAreaRole || roleValue == kAXTextFieldRole {
                
                // Check if it's editable
                var editable: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXEditableAttribute as CFString, &editable) == .success {
                    return editable as? Bool ?? false
                }
            }
        }
        
        return false
    }
    
    // MARK: - Selection Handling
    private func getCurrentSelection() -> [String: Any]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let pid = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier
        var windowInfo = getWindowInfoForPID(pid: pid)
        let windowTitle = windowInfo["windowTitle"] as? String
        
        // Determine editability based on context
        let isEditable: Bool = {
            if isGoogleDocsContext(bundleID: bundleID, windowTitle: windowTitle) {
                return true
            }
            if isTextEditorContext(bundleID: bundleID) {
                return true
            }
            if isWebBrowser(bundleID: bundleID) {
                return hasEditableFocus(pid: pid)
            }
            return hasEditableFocus(pid: pid)
        }()
        
        // Get selection content
        var selectionInfo: [String: Any]?
        
        if isGoogleDocsContext(bundleID: bundleID, windowTitle: windowTitle) {
            selectionInfo = getGoogleDocsSelection(pid: pid)
        } else if isWebBrowser(bundleID: bundleID) {
            selectionInfo = getWebAppSelection(pid: pid)
        } else {
            selectionInfo = getNativeAppSelection(pid: pid)
        }
        
        // Merge results
        if var selection = selectionInfo {
            selection["isEditable"] = isEditable
            selection["window"] = windowInfo
            return selection
        }
        
        return nil
    }
    
    private func getGoogleDocsSelection(pid: pid_t) -> [String: Any]? {
        guard let text = getSelectedTextViaClipboard(enhanced: true) else {
            return nil
        }
        
        let mousePos = currentMouseTopLeftPosition()
        return [
            "text": text,
            "position": ["x": mousePos.x, "y": mousePos.y],
            "source": "google-docs"
        ]
    }

    private func getWebAppSelection(pid: pid_t) -> [String: Any]? {
        if let nativeSelection = getNativeAppSelection(pid: pid) {
            return nativeSelection
        }
        
        if let clipboardText = getSelectedTextViaClipboard(enhanced: false) {
            let mousePos = currentMouseTopLeftPosition()
            return [
                "text": clipboardText,
                "position": ["x": mousePos.x, "y": mousePos.y]
            ]
        }
        
        return nil
    }
        
    private func getNativeAppSelection(pid: pid_t) -> [String: Any]? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowInfo: [String: Any] = [
            "appName": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown",
            "appPID": pid,
            "windowTitle": ""
        ]
        
        if let focusedElement = getFocusedElement(appElement),
           let (text, updatedWindowInfo) = getSelectedText(from: focusedElement, windowInfo: windowInfo) {
            windowInfo = updatedWindowInfo
            let mousePos = currentMouseTopLeftPosition()
            return [
                "text": text,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "window": windowInfo
            ]
        }
        
        if let mainWindow = getMainWindow(appElement),
           let (text, updatedWindowInfo) = getSelectedText(from: mainWindow, windowInfo: windowInfo) {
            windowInfo = updatedWindowInfo
            let mousePos = currentMouseTopLeftPosition()
            return [
                "text": text,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "window": windowInfo
            ]
        }
        
        return nil
    }
    
    private func getFocusedElement(_ appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        return (focusedElement as! AXUIElement)
    }
    
    private func getMainWindow(_ appElement: AXUIElement) -> AXUIElement? {
        var mainWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow) == .success else {
            return nil
        }
        return (mainWindow as! AXUIElement)
    }
    
    private func getSelectedText(from element: AXUIElement, windowInfo: [String: Any]) -> (String, [String: Any])? {
        var updatedWindowInfo = windowInfo
        var selectedText: CFTypeRef?
        
        if let window = getWindowForElement(element),
           let title = getWindowTitle(window) {
            updatedWindowInfo["windowTitle"] = title
        }
        
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
              let text = selectedText as? String else {
            return nil
        }
        
        return (text, updatedWindowInfo)
    }
    
    private func getWindowForElement(_ element: AXUIElement) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success else {
            return nil
        }
        return (window as! AXUIElement)
    }
    
    private func getWindowTitle(_ window: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
    
    private func getWindowInfoForPID(pid: pid_t) -> [String: Any] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowInfo: [String: Any] = [
            "appName": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown",
            "appPID": pid,
            "windowTitle": ""
        ]
        
        if let window = getMainWindow(appElement),
           let title = getWindowTitle(window) {
            windowInfo["windowTitle"] = title
        }
        
        return windowInfo
    }
    
    // MARK: - Enhanced Clipboard Handling
    private func getSelectedTextViaClipboard(enhanced: Bool = false) -> String? {
        guard !isProcessingClipboard else { return nil }
        isProcessingClipboard = true
        defer { isProcessingClipboard = false }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.ensureEventTapActive() } }
        
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount
        
        if enhanced {
            for _ in 1...3 {
                pasteboard.clearContents()
                simulateCopyCommand()
                
                let startTime = CFAbsoluteTimeGetCurrent()
                while CFAbsoluteTimeGetCurrent() - startTime < 0.5 {
                    if pasteboard.changeCount > originalChangeCount,
                       let text = pasteboard.string(forType: .string),
                       !text.isEmpty {
                        pasteboard.clearContents()
                        if let original = originalContent {
                            pasteboard.setString(original, forType: .string)
                        }
                        return text
                    }
                    usleep(50000)
                }
                usleep(100000)
            }
        } else {
            pasteboard.clearContents()
            simulateCopyCommand()
            
            let startTime = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - startTime < 0.3 {
                if pasteboard.changeCount > originalChangeCount,
                   let text = pasteboard.string(forType: .string) {
                    pasteboard.clearContents()
                    if let original = originalContent {
                        pasteboard.setString(original, forType: .string)
                    }
                    return text
                }
                usleep(10000)
            }
        }
        
        pasteboard.clearContents()
        if let original = originalContent {
            pasteboard.setString(original, forType: .string)
        }
        return nil
    }
    
    private func simulateCopyCommand() {
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: loc)
        usleep(30000)
        keyUp?.post(tap: loc)
    }
    
    // MARK: - Mouse Event Handling
    private func setupMouseEventListener() {
        let mouseEventMask =
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)
        
        let observerRef = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mouseEventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let observer = Unmanaged<SelectionObserver>.fromOpaque(refcon!).takeUnretainedValue()
                return observer.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observerRef
        )
        
        if let eventTap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            print("Error: Failed to create event tap. Accessibility permissions may be required.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.setupMouseEventListener()
            }
        }
    }
    
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        modifierState.update(with: event)
        
        switch type {
        case .leftMouseDown:
            mouseIsDragging = false
            
        case .leftMouseDragged:
            mouseIsDragging = true
            
        case .leftMouseUp:
            handleMouseUp(event: event)
            
        case .mouseMoved:
            handleMouseMoved(event: event)
            
        default:
            break
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func handleMouseUp(event: CGEvent) {
        mouseUpSelectionCheckTimer?.invalidate()
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let wasDrag = mouseIsDragging
        let modifiers = modifierState.lockCurrentState()
        
        mouseUpSelectionCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 0.08,
            repeats: false
        ) { [weak self] _ in
            self?.handleSelectionOrDeselection(
                wasDrag: wasDrag,
                clickCount: clickCount,
                modifiers: modifiers
            )
        }
        mouseIsDragging = false
    }
    
    private func handleMouseMoved(event: CGEvent) {
        if popupShown, let popupPos = lastPopupPosition {
            let pos = event.location
            let dx = abs(pos.x - popupPos.x)
            let dy = abs(pos.y - popupPos.y)
            if dx > 130 || dy > 80 {
                sendResetSignal()
            }
        }
    }
    
    // MARK: - Selection Handling
    private func handleSelectionOrDeselection(wasDrag: Bool, clickCount: Int, modifiers: ModifierFlags) {
        guard let selection = getCurrentSelection() else {
            if popupShown { sendResetSignal() }
            return
        }
        
        let selectedText = selection["text"] as? String ?? ""
        lastWindowInfo = selection["window"] as? [String: Any]
        
        let hasMeaningfulText = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        // Handle all selection types: drag, double-click, triple-click
        if (wasDrag || clickCount >= 2) && hasMeaningfulText && selectedText != lastSelectionText {
            initialMousePosition = NSEvent.mouseLocation
            pendingSelectionText = selectedText
            pendingSelectionTimer?.invalidate()
            
            pendingSelectionTimer = Timer.scheduledTimer(
                withTimeInterval: timeThreshold,
                repeats: false
            ) { [weak self] _ in
                self?.handlePendingSelection(modifiers: modifiers)
            }
        } else if !hasMeaningfulText && popupShown {
            sendResetSignal()
        }
    }
    
    private func handlePendingSelection(modifiers: ModifierFlags) {
        guard let pendingText = pendingSelectionText else { return }
        
        let currentMousePos = NSEvent.mouseLocation
        let initialPos = initialMousePosition ?? currentMousePos
        
        let dx = abs(currentMousePos.x - initialPos.x)
        let dy = abs(currentMousePos.y - initialPos.y)
        
        if dx <= positionThreshold && dy <= positionThreshold {
            let mousePos = currentMouseTopLeftPosition()
            lastSelectionText = pendingText
            lastPopupPosition = CGPoint(x: mousePos.x, y: mousePos.y)
            popupShown = true
            
            var selectionData: [String: Any] = [
                "text": pendingText,
                "position": ["x": mousePos.x, "y": mousePos.y],
                "window": lastWindowInfo ?? [:]
            ]
            
            // Get fresh selection data for accurate state
            if let currentSelection = getCurrentSelection() {
                if let isEditable = currentSelection["isEditable"] as? Bool {
                    selectionData["isEditable"] = isEditable
                }
                if let source = currentSelection["source"] as? String {
                    selectionData["source"] = source
                }
            }
            
            // Add modifiers if needed
            if !modifiers.isEmpty {
                var modifierStrings: [String] = []
                if modifiers.contains(.shift)    { modifierStrings.append("shift") }
                if modifiers.contains(.control)  { modifierStrings.append("control") }
                if modifiers.contains(.option)   { modifierStrings.append("option") }
                if modifiers.contains(.command)  { modifierStrings.append("command") }
                
                selectionData["modifiers"] = modifierStrings
            }
            
            sendSignalIfChanged(selectionData)
        }
        
        pendingSelectionText = nil
        pendingSelectionTimer = nil
        initialMousePosition = nil
    }
    
    // MARK: - Signal Handling
    private func sendSignalIfChanged(_ dict: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8),
              jsonString != lastSentSignal else {
            return
        }
        
        print(jsonString, terminator: "\n")
        fflush(stdout)
        lastSentSignal = jsonString
    }
    
    private func sendResetSignal() {
        let mousePos = currentMouseTopLeftPosition()
        let empty: [String: Any] = [
            "text": "",
            "position": ["x": mousePos.x, "y": mousePos.y]
        ]
        sendSignalIfChanged(empty)
        resetSelectionState()
    }
    
    private func resetSelectionState() {
        popupShown = false
        lastPopupPosition = nil
        lastSelectionText = ""
        lastWindowInfo = nil
        pendingSelectionText = nil
        pendingSelectionTimer?.invalidate()
        pendingSelectionTimer = nil
        initialMousePosition = nil
    }
    
    // MARK: - Position Utilities
    private func currentMouseTopLeftPosition() -> (x: CGFloat, y: CGFloat) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screenFrame = screen?.frame else {
            let h = NSScreen.main?.frame.height ?? 0
            return (mouseLocation.x, h - mouseLocation.y)
        }
        let flippedY = screenFrame.origin.y + screenFrame.size.height - mouseLocation.y
        return (mouseLocation.x, flippedY)
    }
    
    // MARK: - Paste Handling
    private func listenForProcessedText() {
        DispatchQueue.global().async { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async {
                    self?.handleIncomingText(line)
                }
            }
        }
    }
    
    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            copyAndPaste(text: text)
            return
        }
        
        let processedText = json["text"] as? String ?? text
        let targetPID = json["appPID"] as? pid_t
        
        copyAndPaste(text: processedText, targetAppPID: targetPID)
    }
    
    private func copyAndPaste(text: String, targetAppPID: pid_t? = nil) {
        copyToClipboard(text)
        performPaste(targetAppPID: targetAppPID ?? (lastWindowInfo?["appPID"] as? pid_t))
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func performPaste(targetAppPID: pid_t?) {
        guard let pid = targetAppPID else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.ensureEventTapActive() } }
        
        sendResetSignal()
        activateApplication(pid: pid)
        focusMainWindow(pid: pid)
        
        let src = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: loc)
        usleep(30000)
        keyUp?.post(tap: loc)
    }
    
    private func activateApplication(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        
        if !app.activate(options: [.activateAllWindows]) {
            let script = """
            tell application "System Events"
                set frontmost of process whose unix id is \(pid) to true
            end tell
            """
            
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            task.launch()
            task.waitUntilExit()
        }
    }
    
    private func focusMainWindow(pid: pid_t) {
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef else {
            return
        }
        
        let windowElement = window as! AXUIElement
        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(150000)
    }
    
    // MARK: - Utilities
    @objc private func windowFocusChanged(_ notification: Notification? = nil) {
        if popupShown {
            sendResetSignal()
        }
        ensureEventTapActive()
    }
    
    private func ensureEventTapActive() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    // MARK: - Main Loop
    func run() {
        CFRunLoopRun()
    }
}

// MARK: - Application Entry Point
let observer = SelectionObserver()
observer.run()