
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

# License

This project is licensed under the MIT License - see the LICENSE file for details.

# Acknowledgement

Big thanks to [Touch-Tab](https://github.com/ris58h/Touch-Tab).


