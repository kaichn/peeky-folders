import AppKit

/// User preferences. Stored in the defaults domain of whichever process runs
/// the browser (the app or the sandboxed Quick Look extension).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "viewMode": 0,                 // 0 = list, 1 = icons
            "iconSize": 64,
            "foldersOnTop": true,
            "showHidden": false,
            "showThumbnails": true,
            "calculateFolderSizes": true,
            "textSize": 13,
            "hiddenColumns": ["created", "items"],
            "sortKey": "name",
            "sortAscending": true,
            "previewSizeIndex": 1,
            "archiveLimitMB": 1024,        // 0 = no limit
            "previewApps": true,           // Quick Look: use Peeky Folders for these types,
            "previewPackages": true,       // or fall back to the system preview
            "previewDiskImages": true,
        ])
    }

    var viewMode: Int { get { d.integer(forKey: "viewMode") } set { d.set(newValue, forKey: "viewMode") } }
    var iconSize: Int { get { d.integer(forKey: "iconSize") } set { d.set(newValue, forKey: "iconSize") } }
    var foldersOnTop: Bool { get { d.bool(forKey: "foldersOnTop") } set { d.set(newValue, forKey: "foldersOnTop") } }
    var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden") } }
    var showThumbnails: Bool { get { d.bool(forKey: "showThumbnails") } set { d.set(newValue, forKey: "showThumbnails") } }
    var calculateFolderSizes: Bool { get { d.bool(forKey: "calculateFolderSizes") } set { d.set(newValue, forKey: "calculateFolderSizes") } }
    var textSize: Int { get { d.integer(forKey: "textSize") } set { d.set(newValue, forKey: "textSize") } }
    var sortKey: String { get { d.string(forKey: "sortKey") ?? "name" } set { d.set(newValue, forKey: "sortKey") } }
    var sortAscending: Bool { get { d.bool(forKey: "sortAscending") } set { d.set(newValue, forKey: "sortAscending") } }
    var previewSizeIndex: Int { get { d.integer(forKey: "previewSizeIndex") } set { d.set(newValue, forKey: "previewSizeIndex") } }
    var previewApps: Bool { get { d.bool(forKey: "previewApps") } set { d.set(newValue, forKey: "previewApps") } }
    var previewPackages: Bool { get { d.bool(forKey: "previewPackages") } set { d.set(newValue, forKey: "previewPackages") } }
    var previewDiskImages: Bool { get { d.bool(forKey: "previewDiskImages") } set { d.set(newValue, forKey: "previewDiskImages") } }

    /// Whether Quick Look should show this file with Peeky Folders (folders and archives always are).
    func handlesInQuickLook(_ url: URL) -> Bool {
        if DiskImageReader.isDiskImage(url) { return previewDiskImages }
        if PackageReader.isPackage(url) { return previewPackages }
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return previewApps }
        return true
    }

    var archiveLimitMB: Int { get { d.integer(forKey: "archiveLimitMB") } set { d.set(newValue, forKey: "archiveLimitMB") } }

    var hiddenColumns: Set<String> {
        get { Set(d.stringArray(forKey: "hiddenColumns") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "hiddenColumns") }
    }

    static let previewSizes = [NSSize(width: 640, height: 420), NSSize(width: 860, height: 560), NSSize(width: 1120, height: 760)]
    var previewSize: NSSize { Self.previewSizes[min(max(previewSizeIndex, 0), 2)] }
}
