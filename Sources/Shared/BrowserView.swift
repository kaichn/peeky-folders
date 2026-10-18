import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

private let sizeLog = Logger(subsystem: "com.charl.PeekyFolders", category: "sizes")

/// The folder/archive browser shown both in the Quick Look panel and in the app's own windows.
final class BrowserView: NSView {
    struct Column { let id: String; let title: String; let width: CGFloat; let minWidth: CGFloat; let rightAligned: Bool }
    static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 300, minWidth: 120, rightAligned: false),
        Column(id: "modified", title: "Date Modified", width: 150, minWidth: 80, rightAligned: false),
        Column(id: "created", title: "Date Created", width: 150, minWidth: 80, rightAligned: false),
        Column(id: "size", title: "Size", width: 80, minWidth: 50, rightAligned: true),
        Column(id: "kind", title: "Kind", width: 130, minWidth: 60, rightAligned: false),
        Column(id: "items", title: "Items", width: 60, minWidth: 40, rightAligned: true),
    ]

    /// Called when the user picks a different preview window size.
    var onPreferredSizeChange: ((NSSize) -> Void)?

    private let settings = Settings.shared
    private(set) var rootURL: URL?
    private var rootIcon: NSImage?
    private var archiveFileSize: Int64?
    private var isArchive = false
    private var stack: [Entry] = []          // navigation path; last = folder being shown
    private var displayed: [Entry] = []      // sorted children of stack.last

    private let sizeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    private var pendingSizes = Set<ObjectIdentifier>()
    private var pendingThumbs = Set<ObjectIdentifier>()
    private var generation = 0
    private var suppressSortCallback = false
    private var headerUpdateScheduled = false

    // UI
    private let backButton = NSButton()
    private let headerIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let gearButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let outline = NSOutlineView()
    private let listScroll = NSScrollView()
    private let grid = IconCollectionView()
    private let gridLayout = NSCollectionViewFlowLayout()
    private let gridScroll = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let contextMenu = NSMenu()
    private let columnMenu = NSMenu()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { sizeQueue.cancelAllOperations() }

    /// e.g. "2 items" — used for logging.
    var itemCountDescription: String { "\(displayed.count) items" }

    // MARK: - Loading

    func load(url: URL, completion: ((Error?) -> Void)? = nil) {
        rootURL = url
        resetBackgroundWork()
        let showHidden = settings.showHidden
        let limitMB = settings.archiveLimitMB
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<(Entry, Bool, Int64?), Error> {
                let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if rv.isDirectory == true {
                    let root = FolderLoader.entry(for: url)
                    root.children = try FolderLoader.children(of: root, showHidden: showHidden)
                    return (root, false, nil)
                }
                let fileSize = Int64(rv.fileSize ?? 0)
                let limit = Int64(limitMB) * 1_048_576
                if limit > 0, fileSize > limit { throw ArchiveError.tooLarge(fileSize, limit) }
                return (try ArchiveReader.list(url: url, showHidden: showHidden), true, fileSize)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let (root, archive, fileSize)):
                    self.isArchive = archive
                    self.archiveFileSize = fileSize
                    self.rootIcon = NSWorkspace.shared.icon(forFile: url.path)
                    self.sortTree(root)
                    self.stack = [root]
                    self.showCurrent()
                    completion?(nil)
                case .failure(let error):
                    self.showError(error, for: url)
                    // Too-large archives get our own message; other failures fall back to the system preview.
                    if case ArchiveError.tooLarge = error { completion?(nil) } else { completion?(error) }
                }
            }
        }
    }

    private func reloadRoot() {
        if let url = rootURL { load(url: url) }
    }

    private func showError(_ error: Error, for url: URL) {
        stack = []
        displayed = []
        outline.reloadData()
        grid.reloadData()
        titleLabel.stringValue = url.lastPathComponent
        subtitleLabel.stringValue = ""
        headerIcon.image = NSWorkspace.shared.icon(forFile: url.path)
        backButton.isHidden = true
        messageLabel.stringValue = error.localizedDescription
        messageLabel.isHidden = false
    }

    private func loadedChildren(_ e: Entry) -> [Entry] {
        if e.children == nil, e.fileURL != nil {
            let kids = (try? FolderLoader.children(of: e, showHidden: settings.showHidden)) ?? []
            e.children = sorted(kids)
            scheduleSizes(e.children!)
        }
        return e.children ?? []
    }

    // MARK: - Navigation

    private func showCurrent() {
        guard let current = stack.last else { return }
        displayed = loadedChildren(current)
        outline.reloadData()
        if settings.viewMode == 1 { grid.reloadData() }
        outline.scrollRowToVisible(0)
        scheduleSizes(displayed)

        messageLabel.stringValue = isArchive ? "This archive is empty." : "This folder is empty."
        messageLabel.isHidden = !displayed.isEmpty
        backButton.isHidden = stack.count < 2
        titleLabel.stringValue = stack.map(\.name).joined(separator: " › ")
        headerIcon.image = stack.count == 1 ? rootIcon : IconCache.icon(for: current)
        updateHeader()
    }

    private func navigate(into e: Entry) {
        guard e.isFolderLike else { return }
        resetBackgroundWork()
        stack.append(e)
        showCurrent()
    }

    @objc private func goBack() {
        guard stack.count > 1 else { return }
        resetBackgroundWork()
        stack.removeLast()
        showCurrent()
    }

    private func activate(_ e: Entry) {
        if e.isFolderLike {
            navigate(into: e)
        } else if let url = e.fileURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func outlineDoubleClick() {
        let row = outline.clickedRow
        guard row >= 0, let e = outline.item(atRow: row) as? Entry else { return }
        activate(e)
    }

    // MARK: - Sorting

    private func sorted(_ list: [Entry]) -> [Entry] {
        let key = settings.sortKey, asc = settings.sortAscending, foldersOnTop = settings.foldersOnTop
        return list.sorted { a, b in
            if foldersOnTop, a.isFolderLike != b.isFolderLike { return a.isFolderLike }
            let r: ComparisonResult
            switch key {
            case "size": r = Self.compare(a.size ?? -1, b.size ?? -1)
            case "items": r = Self.compare(a.itemCount ?? -1, b.itemCount ?? -1)
            case "modified": r = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case "created": r = Self.compare(a.created ?? .distantPast, b.created ?? .distantPast)
            case "kind": r = a.kind.localizedStandardCompare(b.kind)
            default: r = a.name.localizedStandardCompare(b.name)
            }
            if r == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private func sortTree(_ e: Entry) {
        guard let kids = e.children else { return }
        e.children = sorted(kids)
        kids.forEach(sortTree)
    }

    private func resortAll() {
        guard let root = stack.first else { return }
        sortTree(root)
        displayed = stack.last?.children ?? []
        outline.reloadData()
        grid.reloadData()
    }

    // MARK: - Background work (folder sizes, thumbnails)

    private func resetBackgroundWork() {
        sizeQueue.cancelAllOperations()
        pendingSizes.removeAll()
        generation += 1
    }

    private func scheduleSizes(_ list: [Entry]) {
        guard settings.calculateFolderSizes else { return }
        let gen = generation
        let showHidden = settings.showHidden
        for e in list where e.isDirectory && e.size == nil {
            guard let url = e.fileURL else { continue }
            let oid = ObjectIdentifier(e)
            if pendingSizes.contains(oid) { continue }
            pendingSizes.insert(oid)
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, unowned op] in
                let size = FolderLoader.directorySize(path: url.path) { op.isCancelled }
                let count = e.isFolderLike
                    ? (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { showHidden || !$0.hasPrefix(".") }.count
                    : nil
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.pendingSizes.remove(oid)
                    if let size {
                        sizeLog.debug("\(e.name, privacy: .public): \(size) bytes, \(count ?? -1) items")
                        e.size = size
                        e.itemCount = count
                    }
                    self.refresh(e)
                }
            }
            sizeQueue.addOperation(op)
        }
    }

    private static func wantsThumbnail(_ t: UTType) -> Bool {
        t.conforms(to: .image) || t.conforms(to: .pdf) || t.conforms(to: .movie)
            || t.identifier == "com.adobe.encapsulated-postscript"
    }

    private func requestThumbnail(_ e: Entry, side: CGFloat) {
        guard settings.showThumbnails, !e.isDirectory, let url = e.fileURL,
              let type = e.utType, Self.wantsThumbnail(type), e.thumbnailSide < side else { return }
        let oid = ObjectIdentifier(e)
        guard !pendingThumbs.contains(oid) else { return }
        pendingThumbs.insert(oid)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side),
            scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingThumbs.remove(oid)
                e.thumbnailSide = side           // also on failure, so we don't retry endlessly
                if let rep {
                    e.thumbnail = rep.nsImage
                    self.refresh(e)
                }
            }
        }
    }

    private func image(for e: Entry) -> NSImage {
        (settings.showThumbnails ? e.thumbnail : nil) ?? IconCache.icon(for: e)
    }

    /// Redraws one entry wherever it is visible.
    private func refresh(_ e: Entry) {
        let row = outline.row(forItem: e)
        if row >= 0 {
            outline.reloadData(forRowIndexes: IndexSet(integer: row),
                               columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }
        if settings.viewMode == 1, let i = displayed.firstIndex(where: { $0 === e }),
           let item = grid.item(at: IndexPath(item: i, section: 0)) as? IconItem {
            configure(item, with: e)
        }
        scheduleHeaderUpdate()
    }

    private func sizeText(_ e: Entry) -> String {
        if let s = e.size { return Self.bytes(s) }
        if e.isDirectory, pendingSizes.contains(ObjectIdentifier(e)) { return "Calculating…" }
        return "--"
    }

    // MARK: - Header

    private func scheduleHeaderUpdate() {
        guard !headerUpdateScheduled else { return }
        headerUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.headerUpdateScheduled = false
            self?.updateHeader()
        }
    }

    private func updateHeader() {
        guard !stack.isEmpty else { return }
        let n = displayed.count
        var parts = [n == 1 ? "1 item" : "\(n) items"]
        let anyPending = displayed.contains { pendingSizes.contains(ObjectIdentifier($0)) }
        let total = displayed.compactMap(\.size).reduce(0, +)
        if anyPending {
            parts.append("\(Self.bytes(total)) so far…")
        } else if displayed.contains(where: { $0.size != nil }) {
            parts.append(Self.bytes(total))
        }
        if isArchive, stack.count == 1, let packed = archiveFileSize {
            parts.append("\(Self.bytes(packed)) compressed")
        }
        subtitleLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: - Setup

    private func setUp() {
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isHidden = true
        backButton.toolTip = "Back"

        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        headerIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modeControl.segmentCount = 2
        modeControl.trackingMode = .selectOne
        modeControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons"), forSegment: 1)
        modeControl.setToolTip("List", forSegment: 0)
        modeControl.setToolTip("Icons", forSegment: 1)
        modeControl.selectedSegment = settings.viewMode
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        gearButton.isBordered = false
        (gearButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        gearButton.toolTip = "Settings"
        rebuildGearMenu()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [backButton, headerIcon, textStack, spacer, modeControl, gearButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        header.setCustomSpacing(4, after: modeControl)

        let separator = NSBox()
        separator.boxType = .separator

        setUpOutline()
        setUpGrid()

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        for v in [header, separator, listScroll, gridScroll, messageLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
        ])
        for scroll in [listScroll, gridScroll] {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        applyMode()
    }

    private func setUpOutline() {
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.style = .fullWidth
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 14
        let hidden = settings.hiddenColumns
        for spec in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            c.title = spec.title
            c.width = spec.width
            c.minWidth = spec.minWidth
            c.headerCell.alignment = spec.rightAligned ? .right : .left
            let ascendingFirst = spec.id == "name" || spec.id == "kind"
            c.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: ascendingFirst)
            c.isHidden = spec.id != "name" && hidden.contains(spec.id)
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(outlineDoubleClick)
        contextMenu.delegate = self
        outline.menu = contextMenu
        columnMenu.delegate = self
        outline.headerView?.menu = columnMenu
        suppressSortCallback = true
        outline.sortDescriptors = [NSSortDescriptor(key: settings.sortKey, ascending: settings.sortAscending)]
        suppressSortCallback = false
        outline.rowHeight = rowHeight

        listScroll.documentView = outline
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
    }

    private func setUpGrid() {
        gridLayout.minimumInteritemSpacing = 6
        gridLayout.minimumLineSpacing = 6
        gridLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = gridLayout
        grid.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        grid.dataSource = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.menu = contextMenu
        grid.onDoubleClick = { [weak self] ip in
            guard let self, ip.item < self.displayed.count else { return }
            self.activate(self.displayed[ip.item])
        }
        applyIconSize()

        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.borderType = .noBorder
    }

    private var rowHeight: CGFloat { max(18, CGFloat(settings.textSize) + 9) }

    private func applyMode() {
        let icons = settings.viewMode == 1
        listScroll.isHidden = icons
        gridScroll.isHidden = !icons
        if icons { grid.reloadData() } else { outline.reloadData() }
    }

    private func applyIconSize() {
        let side = CGFloat(settings.iconSize)
        gridLayout.itemSize = NSSize(width: max(side + 36, 96), height: side + 54)
        gridLayout.invalidateLayout()
        grid.reloadData()
    }

    @objc private func modeChanged() {
        settings.viewMode = modeControl.selectedSegment
        applyMode()
    }

    // MARK: - Gear menu

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runAction(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, on: Bool? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(run)
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
        return item
    }

    private func addChoice(_ menu: NSMenu, _ title: String, _ options: [(String, Int)], current: Int, _ set: @escaping (Int) -> Void) {
        let sub = NSMenu()
        for (label, value) in options {
            add(sub, label, on: value == current) { [weak self] in
                set(value)
                self?.rebuildGearMenu()
            }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func rebuildGearMenu() {
        let m = NSMenu()
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        m.addItem(titleItem)
        let s = settings

        add(m, "Keep Folders on Top", on: s.foldersOnTop) { [weak self] in
            s.foldersOnTop.toggle(); self?.resortAll(); self?.rebuildGearMenu()
        }
        add(m, "Show Hidden Files", on: s.showHidden) { [weak self] in
            s.showHidden.toggle(); self?.reloadRoot(); self?.rebuildGearMenu()
        }
        add(m, "Show Thumbnails", on: s.showThumbnails) { [weak self] in
            s.showThumbnails.toggle(); self?.outline.reloadData(); self?.grid.reloadData(); self?.rebuildGearMenu()
        }
        add(m, "Calculate Folder Sizes", on: s.calculateFolderSizes) { [weak self] in
            guard let self else { return }
            s.calculateFolderSizes.toggle()
            if s.calculateFolderSizes { self.scheduleSizes(self.displayed) } else { self.resetBackgroundWork() }
            self.outline.reloadData(); self.grid.reloadData(); self.updateHeader(); self.rebuildGearMenu()
        }
        m.addItem(.separator())
        addChoice(m, "Text Size", [("Small", 11), ("Medium", 13), ("Large", 15), ("Extra Large", 17)], current: s.textSize) { [weak self] v in
            guard let self else { return }
            s.textSize = v
            self.outline.rowHeight = self.rowHeight
            self.outline.reloadData()
            self.grid.reloadData()
        }
        addChoice(m, "Icon Size", [("Small", 48), ("Medium", 64), ("Large", 96), ("Extra Large", 128), ("Huge", 192)], current: s.iconSize) { [weak self] v in
            s.iconSize = v; self?.applyIconSize()
        }
        addChoice(m, "Preview Window Size", [("Small", 0), ("Medium", 1), ("Large", 2)], current: s.previewSizeIndex) { [weak self] v in
            s.previewSizeIndex = v; self?.onPreferredSizeChange?(s.previewSize)
        }
        addChoice(m, "Archive Size Limit", [("100 MB", 100), ("500 MB", 500), ("1 GB", 1024), ("4 GB", 4096), ("No Limit", 0)], current: s.archiveLimitMB) { v in
            s.archiveLimitMB = v
        }
        gearButton.menu = m
    }

    // MARK: - Context menu & copying

    private func targetEntries() -> [Entry] {
        if settings.viewMode == 1 {
            return grid.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < displayed.count ? displayed[$0] : nil }
        }
        var rows = outline.selectedRowIndexes
        let clicked = outline.clickedRow
        if clicked >= 0, !rows.contains(clicked) { rows = IndexSet(integer: clicked) }
        return rows.compactMap { outline.item(atRow: $0) as? Entry }
    }

    private func copyFiles(_ entries: [Entry]) {
        let urls = entries.compactMap(\.fileURL)
        guard !urls.isEmpty else { return copyPaths(entries) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    private func copyPaths(_ entries: [Entry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entries.map(\.displayPath).joined(separator: "\n"), forType: .string)
    }

    /// ⌘C
    @objc func copy(_ sender: Any?) {
        let t = targetEntries()
        if !t.isEmpty { copyFiles(t) }
    }

    private func toggleColumn(_ id: String) {
        guard let col = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        col.isHidden.toggle()
        var hidden = settings.hiddenColumns
        if col.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        settings.hiddenColumns = hidden
    }

    // MARK: - Icons view cells

    fileprivate func configure(_ item: IconItem, with e: Entry) {
        let side = CGFloat(settings.iconSize)
        item.setIconSide(side)
        item.iconView.image = image(for: e)
        item.nameLabel.stringValue = e.name
        item.nameLabel.font = .systemFont(ofSize: CGFloat(settings.textSize) - 1)
        if e.isFolderLike, let n = e.itemCount {
            item.detailLabel.stringValue = (n == 1 ? "1 item" : "\(n) items") + (e.size.map { " · " + Self.bytes($0) } ?? "")
        } else {
            let s = sizeText(e)
            item.detailLabel.stringValue = s == "--" ? "" : s
        }
        item.view.toolTip = e.name
        requestThumbnail(e, side: side)
    }
}

// MARK: - Outline view

extension BrowserView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func children(of item: Any?) -> [Entry] {
        guard let e = item as? Entry else { return displayed }
        return loadedChildren(e)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let e = item as? Entry, e.isFolderLike else { return false }
        return e.fileURL != nil || !(e.children ?? []).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let sd = outlineView.sortDescriptors.first, let key = sd.key else { return }
        settings.sortKey = key
        settings.sortAscending = sd.ascending
        resortAll()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let e = item as? Entry, let column = tableColumn else { return nil }
        let id = column.identifier
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        cell.textField?.font = .systemFont(ofSize: CGFloat(settings.textSize))
        let text: String
        switch id.rawValue {
        case "name":
            text = e.name
            cell.imageView?.image = image(for: e)
            requestThumbnail(e, side: outlineView.rowHeight)
        case "modified": text = e.modified.map(Self.dateFormatter.string(from:)) ?? "--"
        case "created": text = e.created.map(Self.dateFormatter.string(from:)) ?? "--"
        case "size": text = sizeText(e)
        case "kind": text = e.kind
        case "items": text = e.isFolderLike ? (e.itemCount.map(String.init) ?? "--") : ""
        default: text = ""
        }
        cell.textField?.stringValue = text
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.lineBreakMode = id.rawValue == "name" ? .byTruncatingMiddle : .byTruncatingTail
        tf.textColor = id.rawValue == "name" ? .labelColor : .secondaryLabelColor
        tf.alignment = Self.columns.first { $0.id == id.rawValue }?.rightAligned == true ? .right : .left
        cell.addSubview(tf)
        cell.textField = tf
        var constraints = [
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            constraints += [
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.heightAnchor.constraint(equalTo: cell.heightAnchor, constant: -3),
                iv.widthAnchor.constraint(equalTo: iv.heightAnchor),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

// MARK: - Icons view

extension BrowserView: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayed.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath) as! IconItem
        configure(item, with: displayed[indexPath.item])
        return item
    }
}

// MARK: - Menus

extension BrowserView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === columnMenu {
            for spec in Self.columns where spec.id != "name" {
                let hidden = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(spec.id))?.isHidden ?? true
                add(menu, spec.title, on: !hidden) { [weak self] in self?.toggleColumn(spec.id) }
            }
            return
        }
        let targets = targetEntries()
        guard !targets.isEmpty else { return }
        let urls = targets.compactMap(\.fileURL)
        if targets.count == 1, let e = targets.first, e.isFolderLike {
            add(menu, "Show Contents") { [weak self] in self?.navigate(into: e) }
        }
        if !urls.isEmpty {
            add(menu, "Open") { urls.forEach { NSWorkspace.shared.open($0) } }
            add(menu, "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            menu.addItem(.separator())
            add(menu, urls.count > 1 ? "Copy \(urls.count) Items" : "Copy") { [weak self] in self?.copyFiles(targets) }
        } else if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        add(menu, targets.count > 1 ? "Copy Paths" : "Copy Path") { [weak self] in self?.copyPaths(targets) }
        add(menu, targets.count > 1 ? "Copy Names" : "Copy Name") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(targets.map(\.name).joined(separator: "\n"), forType: .string)
        }
    }
}

// MARK: - Icon view item & collection view

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        for sub in [iconView, nameLabel, detailLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        widthConstraint = iconView.widthAnchor.constraint(equalToConstant: 64)
        heightConstraint = iconView.heightAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            widthConstraint, heightConstraint,
            iconView.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
        ])
        view = v
        imageView = iconView
        textField = nameLabel
    }

    func setIconSide(_ side: CGFloat) {
        widthConstraint.constant = side
        heightConstraint.constant = side
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor : nil
        }
    }
}

final class IconCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2,
           let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(ip)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(ip) {
            deselectAll(nil)
            selectItems(at: [ip], scrollPosition: [])
        }
        return super.menu(for: event)
    }
}
