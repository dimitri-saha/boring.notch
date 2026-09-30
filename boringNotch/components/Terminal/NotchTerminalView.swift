//
//  NotchTerminalView.swift
//  boringNotch
//
//  The "Terminal" tab: hosts the shared SwiftTerm view inside the open notch.
//

import AppKit
import Defaults
import SwiftUI

struct NotchTerminalView: View {
    @ObservedObject private var session = TerminalSessionController.shared

    var body: some View {
        ZStack {
            TerminalHostView()
            statusOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    session.isFocused ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.2), value: session.isFocused)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.state {
        case .idle, .starting, .running:
            EmptyView()
        case .exited(let code):
            statusMessage(
                icon: "terminal",
                text: code == 0 ? "Shell exited" : "Shell exited with status \(code)",
                buttonTitle: "Restart"
            )
        case .failed(let reason):
            statusMessage(icon: "exclamationmark.triangle", text: reason, buttonTitle: "Retry")
        }
    }

    private func statusMessage(icon: String, text: String, buttonTitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .imageScale(.large)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(buttonTitle) {
                session.restartSession()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

/// Embeds the single, long-lived terminal view so scrollback and the shell survive tab switches.
struct TerminalHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalContainerView {
        let view = TerminalContainerView()
        view.attach(TerminalSessionController.shared.terminalView)
        return view
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        nsView.attach(TerminalSessionController.shared.terminalView)
    }
}

final class TerminalContainerView: NSView {
    private weak var attachedTerminal: NSView?

    func attach(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        attachedTerminal = terminal
    }

    override func layout() {
        super.layout()
        attachedTerminal?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            TerminalSessionController.shared.hostDidAppear(in: window)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil {
            TerminalSessionController.shared.hostWillDisappear()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The notch app has no Edit menu, so route the usual clipboard shortcuts to the terminal here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let terminal = TerminalSessionController.shared.terminalView
        switch key {
        case "v":
            terminal.paste(self)
            return true
        case "c":
            terminal.copy(self)
            return true
        case "a":
            terminal.selectAll(self)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
