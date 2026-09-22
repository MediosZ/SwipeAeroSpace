
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

After properly installation, you can use the 3-finger swipe to switch between AeroSpace workspaces.

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

Use top-level keys as shown above. Click **Reload Config** in Settings after editing
the file, or restart the app. The button appears when the config file exists,
including when it is empty or invalid.
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

