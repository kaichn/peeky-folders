import AppKit

/// Checks GitHub for a newer release. It only reads the public "latest release" endpoint;
/// nothing about the Mac or its files is sent.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let latestURL = URL(string: "https://api.github.com/repos/kaichn/peeky-folders/releases/latest")!
    private let defaults = UserDefaults.standard
    private let autoKey = "checkForUpdatesAutomatically"
    private let lastCheckKey = "lastUpdateCheck"

    var checksAutomatically: Bool {
        get { defaults.object(forKey: autoKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoKey) }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// On launch: at most once a day, and silent unless there's an update.
    func checkInBackgroundIfDue() {
        guard checksAutomatically else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        check(userInitiated: false)
    }

    /// From the menu: always reports the result.
    @objc func checkNow(_ sender: Any?) { check(userInitiated: true) }

    @objc func toggleAutomatic(_ sender: NSMenuItem) {
        checksAutomatically.toggle()
        sender.state = checksAutomatically ? .on : .off
    }

    private func check(userInitiated: Bool) {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PeekyFolders/\(currentVersion) (+https://github.com/kaichn/peeky-folders)",
                         forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                if release != nil { self.defaults.set(Date(), forKey: self.lastCheckKey) }
                self.handle(release, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(_ release: Release?, error: Error?, userInitiated: Bool) {
        guard let release else {
            if userInitiated {
                alert("Couldn't Check for Updates",
                      error?.localizedDescription ?? "GitHub didn't return a release. Try again later.")
            }
            return
        }
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if Self.isVersion(latest, newerThan: currentVersion) {
            let a = NSAlert()
            a.messageText = "Peeky Folders \(latest) Is Available"
            a.informativeText = "You have version \(currentVersion). Download the new version from GitHub, "
                + "then replace the app in your Applications folder."
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn, let url = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
        } else if userInitiated {
            alert("You're Up to Date", "Peeky Folders \(currentVersion) is the latest version.")
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Compares dotted version numbers: 1.10 > 1.9, 1.0.1 > 1.0, 1.0 == 1.0.0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
