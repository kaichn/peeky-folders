import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?
    private var browserWindows: [NSWindow] = []
    private var openedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        if !openedFiles { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        openedFiles = true
        urls.forEach(openBrowser)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Actions

    @objc func showWelcome() {
        if welcome == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Welcome to Peeky Folders"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            welcome = w
            // Refresh the step ticks when coming back from System Settings.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                guard let self, let w = self.welcome, w.isVisible else { return }
                w.contentView = self.makeWelcomeView()
            }
            w.contentView = makeWelcomeView()
            w.center()
        } else {
            welcome?.contentView = makeWelcomeView()
        }
        welcome?.makeKeyAndOrderFront(nil)
    }

    func makeWelcomeView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = NSTextField(labelWithString: "Peeky Folders")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Peek inside folders and archives without opening them.")
        subtitle.textColor = .secondaryLabelColor

        let enabled = Self.isExtensionEnabled
        let settings = NSButton(title: "Open Settings", target: self, action: #selector(openExtensionSettings))
        let steps = NSStackView(views: [
            stepRow(1, "Move to Applications", "Drag Peeky Folders into your Applications folder.",
                    done: Self.isInApplications),
            stepRow(2, "Turn on the extension", "System Settings → Quick Look → Peeky Folders.",
                    done: enabled, button: enabled ? nil : settings),
            stepRow(3, "Select a folder in Finder", "Or a zip, tar, 7z, rar or other archive."),
            stepRow(4, "Press Space", "See what's inside. Press Space again to close."),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 18
        for row in steps.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }

        let tryButton = NSButton(title: "Try It on a Folder…", target: self, action: #selector(openDocument(_:)))
        tryButton.keyEquivalent = "\r"
        tryButton.controlSize = .large

        let stack = NSStackView(views: [icon, title, subtitle, steps, tryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(28, after: steps)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 28, right: 40)
        steps.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true
        return stack
    }

    /// One onboarding step: a numbered badge (a green tick once done), a short
    /// instruction, a one-line detail and an optional button.
    private func stepRow(_ n: Int, _ title: String, _ detail: String,
                         done: Bool = false, button: NSButton? = nil) -> NSView {
        let symbol = done ? "checkmark.circle.fill" : "\(n).circle.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: done ? "Done" : "Step \(n)")?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        let badge = NSImageView(image: image ?? NSImage())
        badge.contentTintColor = done ? .systemGreen : .controlAccentColor
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 14, weight: .semibold)
        t.textColor = done ? .secondaryLabelColor : .labelColor
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 12)
        d.textColor = .secondaryLabelColor
        let text = NSStackView(views: [t, d])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [badge, text, spacer] + (button.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    static var isInApplications: Bool {
        let dir = Bundle.main.bundleURL.deletingLastPathComponent().path
        return dir == "/Applications" || dir == NSHomeDirectory() + "/Applications"
    }

    /// Asks pluginkit whether the Quick Look extension is enabled (its line starts with "+").
    static var isExtensionEnabled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-i", "com.charl.PeekyFolders.Preview"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces).hasPrefix("+")
    }

    @objc func showAbout() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "By order of the Peeky Folders.\nQuick Look for folders and archives.\n\n",
            attributes: [.font: small, .foregroundColor: NSColor.labelColor, .paragraphStyle: center])
        credits.append(NSAttributedString(
            string: "github.com/kaichn/peeky-folders",
            attributes: [.font: small, .link: URL(string: "https://github.com/kaichn/peeky-folders")!,
                         .paragraphStyle: center]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Peeky Folders",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Carl Chen. Released under the MIT License.",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Preview"
        if panel.runModal() == .OK { panel.urls.forEach(openBrowser) }
    }

    func openBrowser(_ url: URL) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Settings.shared.previewSize),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.representedURL = url
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 260)
        let browser = BrowserView(frame: NSRect(origin: .zero, size: Settings.shared.previewSize))
        browser.onPreferredSizeChange = { [weak w] size in w?.setContentSize(size) }
        w.contentView = browser
        let offset = CGFloat(24 * browserWindows.count)
        let top: CGFloat = NSScreen.main?.visibleFrame.maxY ?? 800
        w.cascadeTopLeft(from: NSPoint(x: 80 + offset, y: top - 40 - offset))
        w.makeKeyAndOrderFront(nil)
        browserWindows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.browserWindows.removeAll { $0 === w }
        }
        browser.load(url: url) { error in
            if let error { NSAlert(error: error).beginSheetModal(for: w) }
        }
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("Peeky Folders", [
            item("About Peeky Folders", #selector(showAbout)),
            .separator(),
            item("Hide Peeky Folders", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Peeky Folders", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o"),
            item("Welcome", #selector(showWelcome)),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Copy", #selector(BrowserView.copy(_:)), "c"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }
}

/// Developer aid: `PeekyFolders --snapshot <folder-or-archive> <out.png> [list|icons]`
/// renders the browser off-screen to a PNG (no Screen Recording permission needed).
func runSnapshot(_ args: [String]) -> Never {
    let url = URL(fileURLWithPath: args[0])
    let out = URL(fileURLWithPath: args[1])
    let s = Settings.shared
    let savedMode = s.viewMode
    if args.count > 2 { s.viewMode = args[2] == "icons" ? 1 : 0 }
    let size = NSSize(width: 860, height: 560)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let browser = BrowserView(frame: NSRect(origin: .zero, size: size))
    window.contentView = browser
    var status: Int32 = 0
    browser.load(url: url) { error in
        if let error { FileHandle.standardError.write(Data("load error: \(error.localizedDescription)\n".utf8)); status = 1 }
        // Give folder sizes and thumbnails a moment to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            browser.layoutSubtreeIfNeeded()
            if let rep = browser.bitmapImageRepForCachingDisplay(in: browser.bounds) {
                browser.cacheDisplay(in: browser.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            s.viewMode = savedMode
            exit(status)
        }
    }
    RunLoop.main.run()
    exit(0)
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--welcome-snapshot") {
    // Developer aid: `PeekyFolders --welcome-snapshot <out.png>` renders the welcome screen.
    app.setActivationPolicy(.prohibited)
    let view = AppDelegate().makeWelcomeView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .windowBackgroundColor
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    app.setActivationPolicy(.prohibited)
    runSnapshot(Array(CommandLine.arguments[(i + 1)...]))
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
