import AppKit

// Everything the app writes (database, images, backups) is owner-only by default.
umask(0o077)

// Menu-bar only: no Dock icon (LSUIElement is also set in Info.plist).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
