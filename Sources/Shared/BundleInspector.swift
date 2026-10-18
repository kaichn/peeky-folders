import Foundation
import Security

/// App bundles (.app and other bundles): version, architectures, minimum macOS and signer,
/// shown above the bundle's contents.
enum BundleInspector {
    static func details(_ url: URL) -> [Detail] {
        guard let bundle = Bundle(url: url) else { return [] }
        let info = bundle.infoDictionary ?? [:]
        var details: [Detail] = []

        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: details.append(Detail(text: "Version \(s) (\(b))"))
        case let (s?, _): details.append(Detail(text: "Version \(s)"))
        case let (nil, b?): details.append(Detail(text: "Build \(b)"))
        default: break
        }
        if let exe = bundle.executableURL, let archs = architectures(exe) { details.append(Detail(text: archs)) }
        if let minOS = info["LSMinimumSystemVersion"] as? String { details.append(Detail(text: "macOS \(minOS)+")) }
        details.append(signature(url))
        return details
    }

    /// Reads the Mach-O header: a universal ("fat") binary lists its architectures up front.
    static func architectures(_ exe: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: exe), let head = try? fh.read(upToCount: 4096),
              head.count >= 8 else { return nil }
        try? fh.close()
        let b = Bytes(head)
        var cpus: [UInt32] = []
        let magicBE = (try? b.u32(0)) ?? 0
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {          // fat / fat64, big-endian
            let n = Int((try? b.u32(4)) ?? 0)
            let stride = magicBE == 0xCAFE_BABF ? 32 : 20
            for i in 0..<min(n, 16) { if let c = try? b.u32(8 + i * stride) { cpus.append(c) } }
        } else if magicBE == 0xCFFA_EDFE || magicBE == 0xCEFA_EDFE {    // thin, little-endian on disk
            if let c = try? b.u32(4) { cpus.append(c.byteSwapped) }
        } else {
            return nil
        }
        let arm = cpus.contains(0x0100_000C), intel = cpus.contains(0x0100_0007)
        switch (arm, intel) {
        case (true, true): return "Universal"
        case (true, false): return "Apple silicon"
        case (false, true): return "Intel"
        default: return nil
        }
    }

    /// Checks the code signature of the main executable (not every resource, which can take
    /// minutes for large apps) and names the signer.
    static func signature(_ url: URL) -> Detail {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return Detail(text: "Signature unknown")
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return Detail(text: "Not signed", warning: true) }
        guard status == errSecSuccess else { return Detail(text: "Signature is not valid", warning: true) }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        guard let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else {
            return Detail(text: "Ad-hoc signed")
        }
        let full = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        if full.hasSuffix("Software Signing") { return Detail(text: "Signed by Apple") }   // "Software Signing", "macOS Software Signing"
        if full.hasPrefix("Apple Mac OS Application Signing") { return Detail(text: "From the App Store") }
        return Detail(text: "Signed by \(PackageReader.signerName(leaf))")
    }
}
