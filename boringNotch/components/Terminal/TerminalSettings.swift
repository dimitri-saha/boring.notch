//
//  TerminalSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct TerminalSettings: View {
    @Default(.enableTerminal) var enableTerminal
    @Default(.terminalFontSize) var terminalFontSize
    @Default(.terminalNotchHeight) var terminalNotchHeight
    @Default(.terminalShellPath) var terminalShellPath
    @ObservedObject private var session = TerminalSessionController.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableTerminal) {
                    Text("Enable terminal tab")
                }
                Defaults.Toggle(key: .terminalKeepNotchOpenWhileFocused) {
                    Text("Keep the notch open while the terminal has keyboard focus")
                }
                .disabled(!enableTerminal)
            } header: {
                Text("General")
            } footer: {
                Text("The shell runs in the Boring Notch helper, outside the app sandbox, so it sees your real home folder and tools. macOS may ask for folder permissions the first time you access Desktop, Documents or Downloads.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $terminalFontSize, in: 9...18, step: 1)
                    Text("\(Int(terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Notch height")
                    Slider(value: $terminalNotchHeight, in: minTerminalNotchHeight...maxTerminalNotchHeight, step: 10)
                    Text("\(Int(terminalNotchHeight)) px")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            } header: {
                Text("Appearance")
            }
            .disabled(!enableTerminal)

            Section {
                TextField("Shell", text: $terminalShellPath, prompt: Text("Login shell (default)"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(statusText)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Restart session") {
                        session.restartSession()
                    }
                }
            } header: {
                Text("Session")
            } footer: {
                Text("Leave the shell empty to use your account's login shell. A custom path such as /bin/bash applies to the next session.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .disabled(!enableTerminal)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Terminal")
    }

    private var statusText: String {
        switch session.state {
        case .idle:
            return "No shell running"
        case .starting:
            return "Starting shell…"
        case .running:
            return "Shell running"
        case .exited(let code):
            return "Shell exited with status \(code)"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}
