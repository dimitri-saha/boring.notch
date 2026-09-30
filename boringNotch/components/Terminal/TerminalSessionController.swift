//
//  TerminalSessionController.swift
//  boringNotch
//
//  Owns the notch terminal: the SwiftTerm view, the XPC connection to the shell running in the
//  unsandboxed helper, and the keyboard-focus handoff between the notch panel and other apps.
//

import AppKit
import Combine
import Defaults
import SwiftTerm

extension Notification.Name {
    /// Posted when the notch terminal gives up keyboard focus, so the notch can close if the pointer already left.
    static let notchTerminalFocusDidEnd = Notification.Name("notchTerminalFocusDidEnd")
}

/// Runs `body` on the main thread in FIFO order. XPC callbacks arrive on a private queue, and
/// output chunks must reach the terminal in the order the shell produced them.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            body()
        }
    }
}

/// SwiftTerm view that claims keyboard focus for the notch when clicked.
final class NotchTerminalTextView: TerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        TerminalSessionController.shared.acquireKeyboardFocus()
        super.mouseDown(with: event)
    }
}

@MainActor
final class TerminalSessionController: ObservableObject {
    static let shared = TerminalSessionController()

    enum SessionState: Equatable {
        case idle
        case starting
        case running
        case exited(Int32)
        case failed(String)
    }

    @Published private(set) var state: SessionState = .idle
    /// True while the notch panel is the key window and the terminal is its first responder.
    @Published private(set) var isFocused = false
    /// True while the terminal tab is showing the terminal in a notch window.
    @Published private(set) var isHostVisible = false

    let terminalView: NotchTerminalTextView

    private static let helperServiceName = "theboringteam.boringnotch.BoringNotchXPCHelper"

    private let clientBridge = TerminalClientBridge()
    private let viewBridge = TerminalViewBridge()
    private var connection: NSXPCConnection?
    private var proxy: BoringNotchXPCHelperProtocol?

    private weak var observedWindow: NSWindow?
    /// The container view currently showing the terminal; appear/disappear callbacks are
    /// delivered asynchronously, so this guards against them arriving out of order.
    private weak var activeHost: NSView?
    private var windowObservers: [NSObjectProtocol] = []
    private var previousApplication: NSRunningApplication?
    private var didActivateApp = false
    private var isAcquiringFocus = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        terminalView = NotchTerminalTextView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 240),
            font: Self.font(size: Defaults[.terminalFontSize])
        )
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminalView.caretColor = .white

        clientBridge.controller = self
        viewBridge.controller = self
        terminalView.terminalDelegate = viewBridge

        Defaults.publisher(.terminalFontSize, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    self?.terminalView.font = Self.font(size: change.newValue)
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableTerminal, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    guard !change.newValue else { return }
                    self?.stopSession()
                    if BoringViewCoordinator.shared.currentView == .terminal {
                        BoringViewCoordinator.shared.currentView = .home
                    }
                }
            }
            .store(in: &cancellables)
    }

    private static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(8, size), weight: .regular)
    }

    // MARK: - Session lifecycle

    var isSessionActive: Bool {
        switch state {
        case .starting, .running:
            return true
        case .idle, .exited, .failed:
            return false
        }
    }

    /// The notch should not auto-close on hover-out while the user is typing into the terminal.
    var shouldKeepNotchOpen: Bool {
        Defaults[.terminalKeepNotchOpenWhileFocused] && isHostVisible && isFocused
    }

    func ensureSessionRunning() {
        guard Defaults[.enableTerminal], !isSessionActive else { return }
        startSession()
    }

    func startSession() {
        tearDownConnection()
        state = .starting

        let connection = NSXPCConnection(serviceName: Self.helperServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        connection.exportedInterface = NSXPCInterface(with: (any BoringNotchTerminalClientProtocol).self)
        connection.exportedObject = clientBridge
        connection.interruptionHandler = { [weak self, weak connection] in
            onMain { self?.connectionDidDrop(connection, reason: "The terminal helper stopped responding.") }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            onMain { self?.connectionDidDrop(connection, reason: "The terminal helper connection was closed.") }
        }
        connection.resume()

        let remote = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            onMain { self?.connectionDidDrop(connection, reason: error.localizedDescription) }
        }
        guard let proxy = remote as? BoringNotchXPCHelperProtocol else {
            connection.invalidate()
            state = .failed("Could not reach the terminal helper.")
            return
        }

        self.connection = connection
        self.proxy = proxy

        let terminal = terminalView.getTerminal()
        let shell = Defaults[.terminalShellPath].trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.startTerminalSession(columns: terminal.cols, rows: terminal.rows, shellPath: shell) { [weak self, weak connection] started, message in
            onMain {
                guard let self, let connection, self.connection === connection else { return }
                if started {
                    self.state = .running
                } else {
                    self.state = .failed(message.isEmpty ? "The shell could not be started." : message)
                    self.tearDownConnection()
                }
            }
        }
    }

    func stopSession() {
        proxy?.stopTerminalSession()
        tearDownConnection()
        state = .idle
    }

    func restartSession() {
        stopSession()
        // RIS: full terminal reset, so the new shell starts on a clean screen.
        terminalView.feed(text: "\u{1b}c")
        startSession()
    }

    private func tearDownConnection() {
        proxy = nil
        if let connection {
            connection.interruptionHandler = nil
            connection.invalidationHandler = nil
            connection.invalidate()
        }
        connection = nil
    }

    private func connectionDidDrop(_ dropped: NSXPCConnection?, reason: String) {
        guard let dropped, dropped === connection, isSessionActive else { return }
        state = .failed(reason)
        tearDownConnection()
    }

    // MARK: - Terminal I/O

    fileprivate func receiveOutput(_ data: Data) {
        guard connection != nil else { return }
        terminalView.feed(byteArray: ArraySlice([UInt8](data)))
    }

    fileprivate func receiveExit(status: Int32) {
        guard connection != nil else { return }
        state = .exited(status)
        tearDownConnection()
    }

    fileprivate func sendInput(_ data: Data) {
        proxy?.writeTerminalInput(data)
    }

    fileprivate func terminalSizeDidChange(columns: Int, rows: Int) {
        proxy?.resizeTerminal(columns: columns, rows: rows)
    }

    // MARK: - Keyboard focus

    /// The notch panel never takes key status on its own, so it never steals focus from other apps.
    /// While the terminal is visible we activate Boring Notch, make the panel key, and hand
    /// activation back to the previous app when the terminal goes away.
    func hostDidAppear(_ host: NSView, in window: NSWindow) {
        activeHost = host
        isHostVisible = true
        observe(window)
        ensureSessionRunning()
        acquireKeyboardFocus()
    }

    func hostWillDisappear(_ host: NSView) {
        guard activeHost === host else { return }
        activeHost = nil
        isHostVisible = false
        releaseKeyboardFocus()
        stopObserving()
    }

    func acquireKeyboardFocus() {
        guard Defaults[.enableTerminal], !isAcquiringFocus, let window = terminalView.window else { return }
        isAcquiringFocus = true
        defer { isAcquiringFocus = false }

        if !NSApp.isActive {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication = front
            }
            NSApp.activate(ignoringOtherApps: true)
            didActivateApp = true
        }

        (window as? BoringNotchSkyLightWindow)?.allowsKeyboardFocus = true
        if !window.isKeyWindow {
            window.makeKey()
        }
        if window.firstResponder !== terminalView {
            window.makeFirstResponder(terminalView)
        }
        isFocused = window.isKeyWindow
    }

    func releaseKeyboardFocus() {
        if let window = terminalView.window ?? observedWindow {
            if window.firstResponder === terminalView {
                window.makeFirstResponder(nil)
            }
            (window as? BoringNotchSkyLightWindow)?.allowsKeyboardFocus = false
        }
        let wasFocused = isFocused
        isFocused = false
        handBackActivation()
        if let window = terminalView.window ?? observedWindow, window.isKeyWindow, !NSApp.isActive {
            // macOS refused to activate us, so the non-activating panel stole key status directly.
            // Ordering it out and back in is the only public way to hand that status back.
            window.orderOut(nil)
            window.orderFrontRegardless()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            NotchSpaceManager.shared.notchSpace.windows.insert(window)
        }
        if wasFocused {
            NotificationCenter.default.post(name: .notchTerminalFocusDidEnd, object: nil)
        }
    }

    private func handBackActivation() {
        guard didActivateApp else { return }
        didActivateApp = false
        let target = previousApplication
        previousApplication = nil
        guard NSApp.isActive else { return }
        if let target, !target.isTerminated, target.activate(from: .current, options: []) {
            return
        }
        NSApp.deactivate()
    }

    private func observe(_ window: NSWindow) {
        stopObserving()
        observedWindow = window
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidBecomeKey() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResignKey() }
            },
        ]
    }

    private func stopObserving() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        observedWindow = nil
    }

    private func windowDidBecomeKey() {
        guard isHostVisible else { return }
        if !isFocused {
            // The panel became key from a click; route through the normal activation flow.
            acquireKeyboardFocus()
        }
        isFocused = true
    }

    private func windowDidResignKey() {
        guard isFocused else { return }
        isFocused = false
        NotificationCenter.default.post(name: .notchTerminalFocusDidEnd, object: nil)
    }
}

// MARK: - Bridges

/// Exported over XPC; the helper calls these from its own queue.
private final class TerminalClientBridge: NSObject, BoringNotchTerminalClientProtocol {
    weak var controller: TerminalSessionController?

    func terminalDidReceiveOutput(_ data: Data) {
        onMain { [weak self] in
            self?.controller?.receiveOutput(data)
        }
    }

    func terminalDidExit(status: Int32) {
        onMain { [weak self] in
            self?.controller?.receiveExit(status: status)
        }
    }
}

/// SwiftTerm calls its delegate on the main thread.
private final class TerminalViewBridge: TerminalViewDelegate {
    weak var controller: TerminalSessionController?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            controller?.terminalSizeDidChange(columns: newCols, rows: newRows)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let payload = Data(data)
        MainActor.assumeIsolated {
            controller?.sendInput(payload)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
