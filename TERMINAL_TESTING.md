# Testing the Terminal tab

This branch adds a **Terminal** tab to the open notch, next to Home and Shelf. The tab hosts
a real login shell (zsh by default) rendered with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## What was added

| Area | Change |
| --- | --- |
| Notch UI | New `terminal.fill` tab. The notch grows taller (320 px by default) while it is selected. |
| Shell hosting | The shell runs inside the existing **BoringNotchXPCHelper** (not sandboxed), so it sees your real home folder, `PATH`, Homebrew, etc. The app talks to it over XPC. |
| Keyboard focus | The notch panel normally refuses keyboard focus. While the Terminal tab is visible, Boring Notch activates itself and hands focus back to the previous app when you leave the tab. |
| Settings | New **Terminal** pane: enable/disable, font size, notch height, custom shell path, restart button. |
| Dependency | `SwiftTerm` 1.18.0 (Swift Package, pinned to an exact version). |

New files:

- `BoringNotchXPCHelper/TerminalSessionHost.swift` – forkpty/exec, output pump, resize, teardown
- `boringNotch/components/Terminal/TerminalSessionController.swift` – XPC client, SwiftTerm view, focus handoff
- `boringNotch/components/Terminal/NotchTerminalView.swift` – the tab's SwiftUI view
- `boringNotch/components/Terminal/TerminalSettings.swift` – settings pane

## Prerequisites

- macOS 15.6 or later (the project targets macOS 14, but Xcode 26 needs 15.6+)
- **Xcode 26** from the Mac App Store or <https://developer.apple.com/download/applications/>
- Command Line Tools alone are **not** enough. After installing Xcode, point the toolchain at it once:

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version   # should print Xcode 26.x
```

## Option A: Run from Xcode (fastest)

1. Quit any running copy of Boring Notch (menu bar ✦ → Quit), including a Homebrew install.
2. Open the project:

   ```bash
   cd ~/Downloads/boring.notch
   open boringNotch.xcodeproj
   ```

3. Wait for **Package Dependencies** to resolve in the left sidebar. Xcode fetches SwiftTerm
   automatically (network required). If it does not, use **File → Packages → Resolve Package Versions**.
4. Select the **boringNotch** scheme and **My Mac** as the destination.
5. In the project settings, target **boringNotch → Signing & Capabilities**, pick your personal
   team (or leave "Sign to Run Locally"). Do the same for the **BoringNotchXPCHelper** target.
6. Press **⌘R**.

The app runs directly from Xcode's build folder. Everything below applies the same way.

## Option B: Build an .app you can copy to /Applications

```bash
cd ~/Downloads/boring.notch
xcodebuild -resolvePackageDependencies -project boringNotch.xcodeproj

xcodebuild build \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=YES

# The app lands here:
open build/Build/Products/Release
```

Then drag **Boring Notch.app** to `/Applications` (replace the old one) and launch it.
Because the build is ad‑hoc signed, macOS may show the "unidentified developer" dialog once.
Right‑click → **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Boring Notch.app"
```

## Test checklist

1. **Tab appears.** Hover the notch to open it. Three tabs should be visible: Home, Shelf, Terminal.
   If you only see Home and Shelf, open Settings (⌘, from the menu bar icon) → **Terminal** → *Enable terminal tab*.
2. **Shell starts.** Click the Terminal tab. The notch grows and a zsh prompt appears within a second.
   Type `pwd` ↩ – it should print your real home folder, not a sandbox container.
3. **Typing works without clicking.** Selecting the tab should already give the terminal focus.
   Try `ls --color`, `top` (quit with `q`), `vim` (`:q`).
4. **Focus handoff.** Click into another app: the notch closes (if the pointer is not on it) and typing goes to that app again.
   Hover the notch and select Terminal again – the same shell and scrollback come back.
5. **Stays open while typing.** With the Terminal tab focused, move the pointer away: the notch stays open
   until you click elsewhere. (Toggle *Keep the notch open while the terminal has keyboard focus* in Settings to change that.)
6. **Scrolling.** Two‑finger scroll up inside the terminal shows scrollback and does **not** close the notch.
7. **Clipboard.** ⌘C copies the selection, ⌘V pastes, ⌘A selects all.
8. **Exit and restart.** Type `exit` ↩. An overlay says the shell exited; click **Restart**.
9. **Settings.** Change the font size and notch height sliders; the terminal updates live.

## Things to expect

- The first time the shell touches Desktop, Documents or Downloads, macOS asks for permission on behalf of Boring Notch. That is normal for any terminal.
- Your `~/.zprofile` and `~/.zshrc` run exactly as in Terminal.app (the shell is started as a login shell).
- The shell keeps running while the notch is closed. Quitting Boring Notch ends it.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| "Could not reach the terminal helper" overlay | The XPC helper is missing from the bundle. In Xcode, make sure the **BoringNotchXPCHelper** target built and is listed under boringNotch → General → *Frameworks, Libraries, and Embedded Content*. Clean build folder (⇧⌘K) and build again. |
| "The shell at … does not exist" | Settings → Terminal → clear the custom shell path. |
| Xcode: "SwiftTerm" package cannot be resolved | Needs internet access; retry **File → Packages → Reset Package Caches**. |
| Typing goes to the wrong app | Click once inside the terminal area; the notch claims focus again. |
| Nothing prints, the tab is blank | Open Console.app and filter for `BoringNotchXPCHelper` to see spawn errors. |

## Removing the feature for a normal build

Settings → Terminal → uncheck *Enable terminal tab*. The tab disappears and the shell is terminated.
