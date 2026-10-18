import CryptoKit
import Foundation
import Security

/// One line of extra information in the preview header, e.g. "Version 1.2" or a warning.
struct Detail {
    var text: String
    var warning = false
}

/// Installer packages (.pkg): lists the files they install, read from the Bom manifests,
/// without unpacking the payload. Also reads the package ID, version, install location,
/// whether it runs install scripts, and who signed it.
enum PackageReader {
    static func isPackage(_ url: URL) -> Bool {
        ["pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL, showHidden: Bool) throws -> (Entry, [Detail]) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue ? try readBundle(url, showHidden: showHidden) : try readFlat(url, showHidden: showHidden)
    }

    // MARK: Flat packages (a xar archive)

    private struct Component { var id = "", version = "", location = "/", files = 0, kbytes = 0, scripts = false }

    private static func readFlat(_ url: URL, showHidden: Bool) throws -> (Entry, [Detail]) {
        let wanted: (String) -> Bool = { name in
            let last = (name as NSString).lastPathComponent
            return last == "Bom" || last == "PackageInfo" || name == "Distribution"
        }
        let (names, files) = try ArchiveReader.extract(url, wanted: wanted)

        // Components are the top level ("Bom") or one folder per component ("app.pkg/Bom").
        var components: [String: Component] = [:]
        for (name, data) in files where (name as NSString).lastPathComponent == "PackageInfo" {
            components[(name as NSString).deletingLastPathComponent] = parsePackageInfo(data)
        }
        for name in names where name.split(separator: "/").contains("Scripts") {
            let comp = name.components(separatedBy: "/Scripts").first.map { $0 == "Scripts" ? "" : $0 } ?? ""
            components[comp, default: Component()].scripts = true
        }

        var items: [ArchiveReader.Item] = []
        for (name, data) in files where (name as NSString).lastPathComponent == "Bom" {
            let comp = (name as NSString).deletingLastPathComponent
            let location = components[comp]?.location ?? "/"
            for item in try BomReader.items(data) {
                items.append(rebase(item, onto: location))
            }
        }
        guard !items.isEmpty || !files.isEmpty else {
            throw ArchiveError.cannotOpen("this doesn't look like an installer package")
        }
        let root = ArchiveReader.buildTree(items, rootName: url.lastPathComponent, showHidden: showHidden)

        var details: [Detail] = []
        let comps = components.values.filter { !$0.id.isEmpty }.sorted { $0.id < $1.id }
        if comps.count == 1, let c = comps.first {
            details.append(Detail(text: c.version.isEmpty ? c.id : "\(c.id) \(c.version)"))
            details.append(Detail(text: "Installs to \(c.location)"))
        } else if comps.count > 1 {
            if let title = files["Distribution"].flatMap(distributionTitle) { details.append(Detail(text: title)) }
            details.append(Detail(text: "\(comps.count) packages"))
        }
        details.append(signatureDetail(url))
        if components.values.contains(where: \.scripts) {
            details.append(Detail(text: "Runs install scripts", warning: true))
        }
        return (root, details)
    }

    /// "./Applications/Foo.app" from a component installed at "/" stays as is; a component
    /// installed at "/Applications/Foo" gets that prefix.
    private static func rebase(_ item: ArchiveReader.Item, onto location: String) -> ArchiveReader.Item {
        var p = item.path
        while p.hasPrefix("./") { p.removeFirst(2) }
        if p == "." { p = "" }
        var base = location
        while base.hasPrefix("/") { base.removeFirst() }
        var copy = item
        copy.path = base.isEmpty ? p : (p.isEmpty ? base : base + "/" + p)
        if copy.path.isEmpty { copy.path = "." }
        return copy
    }

    private static func parsePackageInfo(_ data: Data) -> Component {
        var c = Component()
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return c }
        c.id = root.attribute(forName: "identifier")?.stringValue ?? ""
        c.version = root.attribute(forName: "version")?.stringValue ?? ""
        c.location = root.attribute(forName: "install-location")?.stringValue ?? "/"
        if let payload = root.elements(forName: "payload").first {
            c.files = Int(payload.attribute(forName: "numberOfFiles")?.stringValue ?? "") ?? 0
            c.kbytes = Int(payload.attribute(forName: "installKBytes")?.stringValue ?? "") ?? 0
        }
        if let scripts = root.elements(forName: "scripts").first, (scripts.childCount) > 0 { c.scripts = true }
        return c
    }

    private static func distributionTitle(_ data: Data) -> String? {
        guard let doc = try? XMLDocument(data: data),
              let title = try? doc.nodes(forXPath: "//title").first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, !title.hasPrefix("SU_") else { return nil }
        return title
    }

    // MARK: Signature (in the xar table of contents)

    /// Checks the package signature the way xar defines it: the stored checksum must match a
    /// hash of the table of contents, the RSA signature must match that checksum, and the
    /// certificate must chain to a trusted root.
    static func signatureDetail(_ url: URL) -> Detail {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Detail(text: "Signature unknown") }
        defer { try? fh.close() }
        guard let headerData = try? fh.read(upToCount: 28), headerData.count == 28 else {
            return Detail(text: "Not signed")
        }
        let h = Bytes(headerData)
        guard (try? h.string(0, length: 4)) == "xar!",
              let headerSize = try? h.u16(4),
              let tocCompressed = try? h.u64(8), tocCompressed < 64 << 20 else { return Detail(text: "Not signed") }
        try? fh.seek(toOffset: UInt64(headerSize))
        guard let tocZ = try? fh.read(upToCount: Int(tocCompressed)), tocZ.count > 2,
              let toc = try? (tocZ.dropFirst(2) as NSData).decompressed(using: .zlib) as Data,
              let doc = try? XMLDocument(data: toc) else { return Detail(text: "Signature unknown") }

        func number(_ xpath: String) -> Int? {
            (try? doc.nodes(forXPath: xpath).first?.stringValue).flatMap { $0.flatMap { Int($0) } }
        }
        // The certificates sit in the XML-DSig namespace, so match them by local name.
        let certPath = "/xar/toc/signature//*[local-name()='X509Certificate']"
        guard let sigOffset = number("/xar/toc/signature/offset"), let sigSize = number("/xar/toc/signature/size"),
              let certNodes = try? doc.nodes(forXPath: certPath), !certNodes.isEmpty
        else { return Detail(text: "Not signed") }

        let certs = certNodes
            .compactMap { $0.stringValue.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certs.first, let key = SecCertificateCopyKey(leaf) else {
            return Detail(text: "Signature unknown")
        }
        let name = signerName(leaf)

        // Stored checksum and signature live in the heap, right after the TOC.
        let heap = UInt64(headerSize) + tocCompressed
        let ckOffset = number("/xar/toc/checksum/offset") ?? 0
        let ckSize = number("/xar/toc/checksum/size") ?? 20
        func heapRead(_ offset: Int, _ size: Int) -> Data? {
            try? fh.seek(toOffset: heap + UInt64(offset))
            return try? fh.read(upToCount: size)
        }
        guard let stored = heapRead(ckOffset, ckSize), let signature = heapRead(sigOffset, sigSize) else {
            return Detail(text: "Signature unknown")
        }
        let style = ((try? doc.nodes(forXPath: "/xar/toc/checksum/@style").first?.stringValue) ?? nil) ?? "sha1"
        let computed: Data
        let algorithm: SecKeyAlgorithm
        switch style.lowercased() {
        case "sha256": computed = Data(SHA256.hash(data: tocZ)); algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case "sha512": computed = Data(SHA512.hash(data: tocZ)); algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: computed = Data(Insecure.SHA1.hash(data: tocZ)); algorithm = .rsaSignatureDigestPKCS1v15SHA1
        }
        guard computed == stored,
              SecKeyVerifySignature(key, algorithm, stored as CFData, signature as CFData, nil) else {
            return Detail(text: "Signature is not valid", warning: true)
        }

        var trust: SecTrust?
        SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust)
        var error: CFError?
        if let trust, SecTrustEvaluateWithError(trust, &error) {
            return Detail(text: "Signed by \(name)")
        }
        if let error, CFErrorGetCode(error) == Int(errSecCertificateExpired) {
            return Detail(text: "Signed by \(name) (certificate expired)")
        }
        return Detail(text: "Signed by \(name) (not trusted)", warning: true)
    }

    /// "Developer ID Installer: Microsoft Corporation (UBF8T346G9)" -> "Microsoft Corporation".
    static func signerName(_ cert: SecCertificate) -> String {
        var name = (SecCertificateCopySubjectSummary(cert) as String?) ?? "unknown signer"
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
        return name
    }

    // MARK: Old bundle-style packages (a folder)

    private static func readBundle(_ url: URL, showHidden: Bool) throws -> (Entry, [Detail]) {
        let contents = url.appendingPathComponent("Contents")
        let bom = try Data(contentsOf: contents.appendingPathComponent("Archive.bom"))
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let location = info["IFPkgFlagDefaultLocation"] as? String ?? "/"
        let items = try BomReader.items(bom).map { rebase($0, onto: location) }
        let root = ArchiveReader.buildTree(items, rootName: url.lastPathComponent, showHidden: showHidden)
        var details: [Detail] = []
        if let id = info["CFBundleIdentifier"] as? String {
            let version = info["CFBundleShortVersionString"] as? String ?? ""
            details.append(Detail(text: version.isEmpty ? id : "\(id) \(version)"))
        }
        details.append(Detail(text: "Installs to \(location)"))
        let resources = contents.appendingPathComponent("Resources")
        let scriptNames = ["preinstall", "postinstall", "preflight", "postflight", "preupgrade", "postupgrade"]
        if scriptNames.contains(where: { FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path) }) {
            details.append(Detail(text: "Runs install scripts", warning: true))
        }
        return (root, details)
    }
}
