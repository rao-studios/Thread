import AppKit

// SPM executables launch as background processes by default.
// Setting .regular before App.main() makes macOS treat this
// as a normal foreground app with a dock icon and windows.
NSApplication.shared.setActivationPolicy(.regular)

// Design.swift defines a single light palette (cream ground, ink text, gold
// accent) with no dark counterpart. Without pinning the appearance, AppKit
// renders system controls — text fields, steppers, pickers — dark on a light
// window whenever the user's Mac is in dark mode.
NSApplication.shared.appearance = NSAppearance(named: .aqua)

DatabaseDemoApp.main()
