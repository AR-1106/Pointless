# Pointless

> Cursor without the click.

Pointless is a macOS 26 Tahoe menu-bar app that turns your webcam into a touchless trackpad. Pinch and release to tap; stay pinched and move your middle finger to scroll. Every frame is analyzed on-device with Apple's Vision framework — nothing leaves your Mac.

## Installation

1. Download the latest `Pointless-x.y.z.dmg` from the [Releases](https://github.com/AR-1106/Pointless/releases) page.
2. Open the DMG and drag `Pointless.app` to your Applications folder.
3. Since the app is not currently notarized with an Apple Developer account, you must bypass Gatekeeper on the first launch:
   - Open your Applications folder in Finder.
   - **Right-click (or Control-click)** on `Pointless.app` and select **Open**.
   - Click **Open** in the security dialog that appears.

> Note: If you simply double-click the app on the first launch, macOS will block it from opening. You only need to perform the right-click bypass once.

## Requirements

- macOS 26 Tahoe or newer
- Apple silicon
- Built-in or USB camera

## Development

```bash
open Pointless.xcodeproj
```

Build in Debug and run. The first launch walks through camera + accessibility permissions and a gesture tutorial.

### Project structure

```
Pointless/              Swift sources
  PointlessApp.swift        @main entry point, AppDelegate, Settings scene
  StatusBarController.swift Menu bar item + tracking lifecycle
  CameraManager.swift       AVCaptureSession wrapper
  HandTracker.swift         Vision hand-pose detection
  GestureProcessor.swift    Pinch / dwell / scroll state machine
  CursorController.swift    CGEvent posting + haptics
  CameraPreviewWindow.swift Floating Liquid Glass preview
  HandOverlayWindow.swift   Full-screen click-through skeleton
  OnboardingWindow.swift    First-run SwiftUI flow
  PreferencesView.swift     Settings scene (General/Camera/Gestures/Updates/About)
  SettingsStore.swift       UserDefaults-backed observable settings
  PermissionsManager.swift  Camera + Accessibility status + prompts
  LiquidGlass.swift         Shared motion + material tokens
  SmoothingFilter.swift     1-Euro filter for hand points
  Info.plist
  Pointless.entitlements

design/
  icon.svg                  Source for AppIcon PNGs

scripts/
  generate_icons.sh         Export AppIcon PNGs from the SVG
  release.sh                Archive / sign / notarize / DMG / Sparkle
  ExportOptions.plist       Developer ID export options
  README.md                 Release prerequisites + usage

LAUNCH.md                   Launch-day runbook
```

### Building

```bash
xcodebuild -project Pointless.xcodeproj -scheme Pointless -configuration Debug build
```

The target is macOS 26.0, hardened runtime is on, and App Sandbox is off (required for `CGEvent` posting to control the cursor).

## Releasing

See [scripts/README.md](scripts/README.md) for the full release pipeline. Short version:

```bash
brew install librsvg create-dmg xcpretty
./scripts/generate_icons.sh
./scripts/release.sh 1.0.0 1
```

## Launching

See [LAUNCH.md](LAUNCH.md) for the launch-day checklist.

## License

© 2026 Arjun. All rights reserved.
