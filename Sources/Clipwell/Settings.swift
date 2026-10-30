import Foundation

/// User-adjustable limits, stored in UserDefaults and changed from the menu bar.
enum Settings {
    private static let defaults = UserDefaults.standard

    static let historyLimitChoices = [500, 1_000, 5_000, 10_000]
    static let sensitiveTTLChoices = [0, 10, 60, 1_440] // minutes; 0 keeps them
    static let imageLimitChoices = [250, 500, 1_000, 2_000] // MB

    /// Carries preferences over from the app's old name ("ClipboardHistory"), once.
    static func migrateLegacySettings() {
        guard !defaults.bool(forKey: "migratedFromClipboardHistory"),
              let old = UserDefaults(suiteName: "com.naveen.ClipboardHistory") else { return }
        for key in ["historyLimit", "sensitiveTTLMinutes", "maxImageMB", "excludedBundles"] {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromClipboardHistory")
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            "historyLimit": 1_000,
            "sensitiveTTLMinutes": 60,
            "maxImageMB": 500,
        ])
    }

    /// Unpinned items beyond this are pruned, oldest first.
    static var historyLimit: Int {
        get { defaults.integer(forKey: "historyLimit") }
        set { defaults.set(newValue, forKey: "historyLimit") }
    }

    /// Unpinned values tagged `sensitive` are deleted this long after last use. 0 disables it.
    static var sensitiveTTLMinutes: Int {
        get { defaults.integer(forKey: "sensitiveTTLMinutes") }
        set { defaults.set(newValue, forKey: "sensitiveTTLMinutes") }
    }

    static var maxImageMB: Int {
        get { defaults.integer(forKey: "maxImageMB") }
        set { defaults.set(newValue, forKey: "maxImageMB") }
    }

    /// Apps whose copies are never recorded (added from the menu bar).
    static var excludedBundles: [String] {
        get { defaults.stringArray(forKey: "excludedBundles") ?? [] }
        set { defaults.set(newValue, forKey: "excludedBundles") }
    }

    /// Remote-desktop, virtual-machine and screen-sharing apps. A synthetic ⌘V is not sent into
    /// these (it would paste on the wrong side of the connection); the item is only copied.
    static let noAutoPasteBundles: Set<String> = [
        "com.microsoft.rdc.macos",
        "com.vmware.fusion",
        "com.parallels.desktop.console",
        "com.teamviewer.TeamViewer",
        "com.anydesk.anydesk",
        "com.apple.ScreenSharing",
        "com.utmapp.UTM",
    ]
}
