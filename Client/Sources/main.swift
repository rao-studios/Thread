import AppKit

// SPM executables launch as background processes by default.
// Setting .regular before App.main() makes macOS treat this
// as a normal foreground app with a dock icon and windows.
NSApplication.shared.setActivationPolicy(.regular)
DatabaseDemoApp.main()