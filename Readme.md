
![banner](./assets/banner.png)

# About

Swipe with three fingers to change AeroSpace workspaces. This can be a single purpose alternative to Better Touch Tool.

# Installation

You can either download the pre-built binary (built with github actions) or build it from source.

## Homebrew

The easiest way to install is to use Homebrew:

```bash
brew install --cask mediosz/tap/swipeaerospace
```

## Download pre-built binary

First, Download the latest `SwipeAeroSpace.dmg` from [Releases](https://github.com/MediosZ/SwipeAeroSpace/releases) page.

But it can’t be opened because Apple cannot check it for malicious software.

There are two options:

- You may right-click the app and click Open and click Open again, or you could goto `System Settings > Privacy & Security > Security` and select `Open Anyway`.
- You could use `xattr -d com.apple.quarantine /path/to/SwipeAeroSpace.app` to remove the constraint.

The app needs access to global trackpad events. Allow `SwipeAeroSpace` to control your computer in `System Settings > Privacy & Security > Accessibility`.

## Build from source 

First install Xcode, then there are two options:

- Open `SwipeAeroSpace.xcodeproj` to build the project and export the app.
- Or you can use `xcodebuild` directly to build and export the app.


# Usage 

After installation, SwipeAeroSpace runs in the menu bar and turns trackpad
gestures into AeroSpace commands.

## Workspace Switching

Swipe horizontally with three (or four) fingers to move between workspaces:

- **Sensitivity** — how far fingers must travel per switch
- **Natural swipe direction** — match trackpad scrolling, or invert it
- **Wrap around** — swiping past the last workspace jumps back to the first
- **Skip empty** — only land on workspaces that have windows; when the
  focused workspace itself becomes empty, swipes go to the nearest occupied
  workspace relative to it
- **Multi-workspace swipe** — a longer swipe jumps several workspaces in one
  gesture, up to a configurable maximum (2–9 steps)

## Modifier Gestures

Hold a modifier key when a horizontal swipe starts to remap it:

- **Shift** — carry the focused window to the neighbouring workspace (`move-node-to-workspace next/prev`)
- **Ctrl** — switch monitors instead of workspaces (`focus-monitor next/prev`)

The `natural` and `wrap` settings apply to modifier gestures as well. Vertical
(overview) swipes ignore modifier keys.

## Workspace Overview

Swipe up to open a full-screen overview of all workspaces and their apps,
grouped by monitor. Hovering a workspace previews it live, clicking jumps to
it, and Escape or a swipe back down dismisses the overview. Empty workspaces
can be included via a setting, and the overview is also available from the
menu bar.

Clicking a specific app row focuses that window directly (`focus
--window-id`), switching workspaces automatically if needed. The overview is
fully keyboard-driven: it is key as soon as it opens, so arrow keys move
between workspace cards (left/right) and into a card's window rows
(down/up), Enter confirms the selection, and Escape reverts. Typing a
workspace name's first letters jumps straight to it — a unique match selects
immediately, otherwise a short timeout picks the first candidate. Cards with
more windows than fit scroll internally, and the whole grid scrolls when it
is taller than the screen.

## Menu Bar & Settings

The menu bar icon offers Workspace Overview, Next/Prev Workspace, Settings,
About, and Quit. Every gesture is configurable in the Settings window, and
Launch at Login is supported.

The app keeps a lightweight heartbeat to the AeroSpace daemon and reconnects
automatically, e.g. after AeroSpace restarts or launches after SwipeAeroSpace.

## Configuration

On launch, SwipeAeroSpace reads `$HOME/.config/swipeareospace/config.toml`
(note the directory spelling). Create this file to override settings saved in
UserDefaults. Only keys present in the file are overridden; other settings keep
their saved values or built-in defaults. Removing the file restores saved settings
after reloading or on the next launch. The file never overwrites UserDefaults.

Example with all supported keys and their built-in defaults:

```toml
threshold = 1.0                  # Any finite number greater than zero
wrap = false
natural = true
skip-empty = false
fingers = "Three"               # "Three" or "Four"
multiSwipe = true
maxSteps = 5                     # Integer from 2 through 9
swipeUpOverview = true
swipeUpFingers = "Three"         # "Three" or "Four"
show-empty-workspaces = false
```

Use top-level keys as shown above. The file is watched for changes and reloaded
automatically, so edits take effect without restarting the app. A **Reload Config**
button in Settings remains available as a manual fallback; it appears when the
config file exists, including when it is empty or invalid.
File-controlled settings are read-only in the Settings window; settings omitted
from the file remain editable and are saved to UserDefaults. Launch at Login is
managed separately by macOS and is not a config key. Menu bar visibility remains
a UserDefaults preference and is not configurable through TOML.

If the file is missing, the app uses UserDefaults as before. If it is unreadable,
contains invalid TOML, unknown keys, or invalid values, the entire file is ignored.
The app logs the error and displays it in Settings, using UserDefaults instead.

Run configuration tests with `swift test`. Build the full app with Xcode as above.

# License

This project is licensed under the MIT License - see the LICENSE file for details.

# Acknowledgement

Big thanks to [Touch-Tab](https://github.com/ris58h/Touch-Tab).

