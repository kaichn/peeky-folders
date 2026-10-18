import Cocoa
import QuickLookUI
import os

private let log = Logger(subsystem: "com.charl.PeekyFolders.Preview", category: "preview")

/// Principal class of the Quick Look preview extension. Finder asks it to
/// preview a folder or archive when the user presses Space or ⌘Y.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private lazy var browser = BrowserView(frame: NSRect(origin: .zero, size: Settings.shared.previewSize))

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = browser
        preferredContentSize = Settings.shared.previewSize
        browser.onPreferredSizeChange = { [weak self] size in self?.preferredContentSize = size }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Types turned off in the ⚙︎ menu go to the system's own preview.
        guard Settings.shared.handlesInQuickLook(url) else {
            handler(CocoaError(.featureUnsupported))
            return
        }
        _ = view
        browser.isQuickLook = true
        browser.load(url: url) { [weak self] error in
            if let error {
                log.error("Preview failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Previewed \(url.lastPathComponent, privacy: .public): \(self?.browser.itemCountDescription ?? "?", privacy: .public)")
            }
            handler(error)
        }
    }
}
