# PermissionFlow attribution

Upstream: https://github.com/jaywcjlove/PermissionFlow/tree/v2.11.3

License: MIT, copyright (c) 2026 小弟调调. The full license is in `LICENSE` and is copied into `MicroDesktop.bundle/Contents/Resources/ThirdParty/PermissionFlow-LICENSE` for both Xcode and packaged builds.

Integration:

- `SystemSettingsKit` is consumed directly through SwiftPM, pinned to version 2.11.3. `Package.resolved` records the revision.
- `Sources/MicroDesktop/PermissionAppDragView.swift` adapts `Sources/PermissionFlow/UI/AppDropArea.swift`: native `.app` file dragging with a pure AppKit card. The pasteboard writer is Apple’s `NSURL` implementation; custom legacy `NSFilenamesPboardType` was rejected as an invalid UTI in the actual Catalyst process and has been removed. There is no promised-file representation because the application already exists. Dragging only allows copy operations and never marks a permission granted.
- `Sources/MicroDesktop/PermissionSettingsWindow.swift` adapts the window-server geometry approach in `Sources/PermissionFlow/Tracking/SettingsWindowTracker.swift`, scoped to System Settings. It uses no Accessibility observer or trust prompt, applies no visual coordinate offset, and positions within the current display's visible frame.
- `PermissionSetupCoordinator` and `PermissionSetupView` provide Micro's permission state, localized AppKit panel, bounded tracking lifetime, nonactivating behavior, and drag-time mouse passthrough.

The full `PermissionFlow` UI product is not linked: its native `NSHostingView` cannot be resolved by the iOSSupport SwiftUI framework used in this Mac Catalyst process. `SystemSettingsKit` has no SwiftUI dependency. No optional permission-detection modules are included.
