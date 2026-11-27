import CryptoKit
import Foundation
import Security

/// Signing on a SayoSign server (server/sayosign_server.py). The server gets the certificate,
/// profile and options for one job; it fetches the IPA from its source URL itself when it can,
/// otherwise this iPhone uploads it in parts. Tweaks and the hook framework are uploaded once
/// and reused by checksum. The signed IPA is installed straight from the server and a copy is
/// downloaded into Signed.
enum RemoteSigner {
    /// Cloudflare refuses requests over 100 MB, so files go up in parts of this size.
    static let chunk = 16 * 1024 * 1024

    struct Info {
        var version: String
        var queue: Int
        var freeDisk: Int64
        var ttl: Int
    }

    // MARK: Server key (Keychain)

    private static let keyAccount = "remote-signing-key"

    static var key: String {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.murk.sayosign",
                                    kSecAttrAccount as String: keyAccount, kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.murk.sayosign",
                                       kSecAttrAccount as String: keyAccount]
            SecItemDelete(base as CFDictionary)
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func isConfigured(_ settings: AppSettings) -> Bool {
        !settings.remoteServer.trimmingCharacters(in: .whitespaces).isEmpty && !key.isEmpty
    }

    // MARK: HTTP

    static func base(_ settings: AppSettings) throws -> String {
        var b = settings.remoteServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { throw SayoError(L("Set up the signing server in Settings")) }
        if !b.lowercased().hasPrefix("http") { b = "https://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        return b + "/api"
    }

    struct Response {
        var status: Int
        var json: [String: Any]
        var http: HTTPURLResponse
    }

    final class SendProgress: NSObject, URLSessionTaskDelegate {
        let handler: (Int64) -> Void
        init(_ handler: @escaping (Int64) -> Void) { self.handler = handler }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            handler(totalBytesSent)
        }
    }

    static func request(_ method: String, _ path: String, settings: AppSettings, json: Any? = nil, body: Data? = nil,
                        sent: ((Int64) -> Void)? = nil) async throws -> Response {
        let root = try base(settings)
        guard let url = URL(string: root + path) else { throw SayoError(L("Invalid URL")) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = body != nil ? 600 : 60
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue("SayoSign/1.0", forHTTPHeaderField: "User-Agent")
        var payload: Data?
        if let j = json {
            payload = try JSONSerialization.data(withJSONObject: j)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let b = body {
            payload = b
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        if let p = payload {
            let delegate = SendProgress { sent?($0) }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            (data, resp) = try await session.upload(for: r, from: p)
        } else {
            (data, resp) = try await URLSession.shared.data(for: r)
        }
        guard let http = resp as? HTTPURLResponse else { throw SayoError(L("The signing server did not answer")) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 { throw SayoError(L("The signing server refused the key. Check it in Settings → Signing server.")) }
        if http.statusCode == 403 || (http.statusCode >= 500 && obj.isEmpty) {
            throw SayoError(LF("The signing server is unavailable (HTTP %ld)", http.statusCode))
        }
        return Response(status: http.statusCode, json: obj, http: http)
    }

    static func ping(_ settings: AppSettings) async throws -> Info {
        let r = try await request("GET", "/ping", settings: settings)
        guard r.status == 200, r.json["server"] as? String == "sayosign" else {
            throw SayoError(LF("The signing server is unavailable (HTTP %ld)", r.status))
        }
        return Info(version: r.json["version"] as? String ?? "?", queue: r.json["queue"] as? Int ?? 0,
                    freeDisk: (r.json["free_disk"] as? NSNumber)?.int64Value ?? 0, ttl: r.json["ttl"] as? Int ?? 0)
    }

    // MARK: Files

    static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let d = try h.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if d.isEmpty { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ u: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Uploads a file unless the server has it already, resuming a part-done upload.
    static func upload(_ file: URL, settings: AppSettings, progress: ((Double) -> Void)? = nil) async throws -> String {
        let sha = try sha256(file)
        let total = fileSize(file)
        let head = try await request("HEAD", "/blobs/\(sha)", settings: settings)
        if head.status == 200 { progress?(1); return sha }
        var offset = Int64(head.http.value(forHTTPHeaderField: "X-Upload-Offset") ?? "0") ?? 0
        if offset > total { offset = 0 }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var failures = 0
        while offset < total || total == 0 {
            try h.seek(toOffset: UInt64(offset))
            let part = try h.read(upToCount: chunk) ?? Data()
            let start = offset
            do {
                let r = try await request("PUT", "/blobs/\(sha)?offset=\(offset)&total=\(total)", settings: settings, body: part) { sent in
                    if total > 0 { progress?(Double(start + sent) / Double(total)) }
                }
                if r.json["complete"] as? Bool == true { break }
                if let o = (r.json["offset"] as? NSNumber)?.int64Value {
                    offset = o
                } else {
                    throw SayoError(r.json["error"] as? String ?? "HTTP \(r.status)")
                }
                failures = 0
            } catch let e as URLError {
                // Weak mobile network: retry the part; the server tells where to go on.
                failures += 1
                if failures > 4 { throw e }
                try await Task.sleep(nanoseconds: UInt64(failures) * 2_000_000_000)
                let again = try await request("HEAD", "/blobs/\(sha)", settings: settings)
                if again.status == 200 { break }
                offset = Int64(again.http.value(forHTTPHeaderField: "X-Upload-Offset") ?? "0") ?? 0
            }
            if total == 0 { break }
        }
        progress?(1)
        return sha
    }

    /// A folder (a .framework) as a zip holding that folder, for upload.
    static func zipFolder(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        let root = Paths.work.appendingPathComponent("zip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.copyItem(at: dir, to: root.appendingPathComponent(dir.lastPathComponent))
        let out = Paths.work.appendingPathComponent(UUID().uuidString + ".zip")
        try SayoCore.zip(root, to: out, level: 6)
        return out
    }

    static var hookFramework: URL? {
        guard let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("CydiaSubstrate.framework"),
              FileManager.default.fileExists(atPath: fw.path) else { return nil }
        return fw
    }

    // MARK: Signing

    static func optionsJSON(_ o: SayoCore.SignOptions) -> [String: Any] {
        ["bundle_id": o.bundleID, "name": o.displayName, "version": o.version, "short_version": o.shortVersion,
         "min_ios": o.minIOS, "remove_plugins": o.removePlugins, "remove_watch": o.removeWatch,
         "remove_url_schemes": o.removeURLSchemes, "file_sharing": o.fileSharing, "container": o.container,
         "compression": Int(o.compression)]
    }

    @MainActor static func identityJSON(_ ident: Identity, cert c: StoredCertificate, state: AppState) throws -> [String: Any] {
        var err: Unmanaged<CFError>?
        if let raw = SecKeyCopyExternalRepresentation(ident.key, &err) as Data? {
            return ["key": raw.base64EncodedString(), "cert": ident.certificate.base64EncodedString()]
        }
        if !c.fromAppleID, let files = state.certificateFiles(c) {
            return ["p12": files.p12.base64EncodedString(), "password": files.password]
        }
        throw SayoError(L("This certificate's private key cannot leave the iPhone, sign it here instead"))
    }

    static func stageName(_ s: String) -> String {
        switch s {
        case "upload": return L("Uploading to the server")
        case "queued": return L("Waiting in the server queue")
        case "fetch": return L("Server is downloading the IPA")
        case "unzip": return L("Server is unpacking")
        case "prepare": return L("Patching Info.plist")
        case "inject": return L("Injecting tweaks")
        case "sign": return L("Signing on the server")
        case "zip": return L("Packing IPA")
        case "download": return L("Downloading the signed IPA")
        default: return s
        }
    }
}

extension AppState {
    /// Same inputs as performSign, done by the signing server.
    func performRemoteSign(app: LibraryApp, cert c: StoredCertificate, options: SayoCore.SignOptions, tweaks: [URL],
                           progress: @escaping @MainActor (Double, String) -> Void) async throws -> SignedApp {
        let settings = self.settings
        var opts = options
        opts.compression = Int32(settings.compressionLevel)
        let appName = opts.displayName.isEmpty ? app.name : opts.displayName
        let (ident, profile, prepared) = try await signingMaterial(app: app, cert: c, options: opts, appName: appName, progress: progress)
        opts = prepared
        let identity = try RemoteSigner.identityJSON(ident, cert: c, state: self)

        InstallServer.shared.keepAlive(true)
        defer { InstallServer.shared.keepAlive(false) }
        var temp: [URL] = []
        defer { temp.forEach { try? Paths.fm.removeItem(at: $0) } }

        // Tweaks: small, uploaded once and then found by checksum.
        progress(0.02, "upload")
        func uploadTweak(_ t: URL) async throws -> String {
            var isDir: ObjCBool = false
            Paths.fm.fileExists(atPath: t.path, isDirectory: &isDir)
            var file = t
            if isDir.boolValue {
                file = try await Task.detached { try RemoteSigner.zipFolder(t) }.value
                temp.append(file)
            }
            return try await RemoteSigner.upload(file, settings: settings)
        }
        func uploadHook() async throws -> String? {
            guard let fw = RemoteSigner.hookFramework else { return nil }
            let z = try await Task.detached { try RemoteSigner.zipFolder(fw) }.value
            temp.append(z)
            return try await RemoteSigner.upload(z, settings: settings)
        }
        var tweakRefs: [[String: Any]] = []
        for t in tweaks {
            let sha = try await uploadTweak(t)
            tweakRefs.append(["name": t.lastPathComponent, "sha": sha])
        }
        var spec: [String: Any] = ["identity": identity, "profile": profile.base64EncodedString(),
                                   "options": RemoteSigner.optionsJSON(opts), "tweaks": tweakRefs,
                                   "remove_embedded": opts.removeEmbedded, "title": appName]
        if !tweaks.isEmpty, let sha = try await uploadHook() {
            spec["hook"] = ["sha": sha]
        }
        if let icon = opts.iconPNG, let d = try? Data(contentsOf: icon) { spec["icon"] = d.base64EncodedString() }
        if let e = opts.entitlements, let d = try? Data(contentsOf: e) { spec["entitlements"] = d.base64EncodedString() }

        // The IPA: from its source URL when there is one, else packed from the library and uploaded.
        var serverStart = 0.05
        func uploadIPA() async throws -> String {
            progress(0.03, "upload")
            // Signed on the server before: ask by checksum, no packing and no upload if it is still there.
            if let known = library.first(where: { $0.id == app.id })?.remoteSHA,
               let head = try? await RemoteSigner.request("HEAD", "/blobs/\(known)", settings: settings), head.status == 200 {
                return known
            }
            let dir = Paths.library.appendingPathComponent(app.id.uuidString, isDirectory: true)
            let zip = Paths.work.appendingPathComponent(UUID().uuidString + ".ipa")
            temp.append(zip)
            try await Task.detached { try SayoCore.zip(dir, to: zip, level: 0) }.value
            let sha = try await RemoteSigner.upload(zip, settings: settings) { f in
                Task { @MainActor in progress(0.05 + 0.4 * f, "upload") }
            }
            serverStart = 0.45
            if let i = library.firstIndex(where: { $0.id == app.id }) {
                library[i].remoteSHA = sha
                save()
            }
            try? Paths.fm.removeItem(at: zip)
            return sha
        }
        if let origin = app.originURL, origin.lowercased().hasPrefix("http") {
            spec["ipa"] = ["url": origin]
        } else {
            let sha = try await uploadIPA()
            spec["ipa"] = ["sha": sha]
        }

        var job: [String: Any] = [:]
        var attempts = 0
        while true {
            attempts += 1
            var r = try await RemoteSigner.request("POST", "/jobs", settings: settings, json: spec)
            if r.status == 409, let need = r.json["need"] as? [String] {
                // The server dropped an upload from its cache meanwhile.
                if let ipa = spec["ipa"] as? [String: String], let sha = ipa["sha"], need.contains(sha) {
                    let again = try await uploadIPA()
                    spec["ipa"] = ["sha": again]
                }
                for (i, t) in tweaks.enumerated() where need.contains(tweakRefs[i]["sha"] as? String ?? "") {
                    _ = try await uploadTweak(t)
                }
                if let h = spec["hook"] as? [String: String], need.contains(h["sha"] ?? ""), let sha = try await uploadHook() {
                    spec["hook"] = ["sha": sha]
                }
                r = try await RemoteSigner.request("POST", "/jobs", settings: settings, json: spec)
            }
            guard r.status == 202, let id = r.json["id"] as? String else {
                throw SayoError(r.json["error"] as? String ?? LF("The signing server is unavailable (HTTP %ld)", r.status))
            }
            job = try await waitForJob(id, settings: settings, serverStart: serverStart, progress: progress)
            if job["state"] as? String == "done" { break }
            let code = job["error_code"] as? String ?? ""
            // The server could not fetch the source URL (login, expired link...): upload it instead.
            if code == "fetch", attempts == 1, (spec["ipa"] as? [String: String])?["url"] != nil {
                let sha = try await uploadIPA()
                spec["ipa"] = ["sha": sha]
                continue
            }
            throw SayoError(L("Server") + ": " + (job["error"] as? String ?? L("Signing failed")))
        }

        guard let result = job["result"] as? [String: Any], let ipa = (result["ipa_url"] as? String).flatMap(URL.init(string:)) else {
            throw SayoError(L("Signing failed"))
        }
        progress(0.9, "download")
        let downloaded = try await Downloader.download(ipa, tag: "remote|\(app.id.uuidString)") { f in
            Task { @MainActor in progress(0.9 + 0.1 * f, "download") }
        }
        let finalName = result["name"] as? String ?? appName
        let finalVersion = result["version"] as? String ?? ""
        let safe = finalName.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safe)_\(finalVersion)_\(UUID().uuidString.prefix(6)).ipa"
        let out = Paths.signed.appendingPathComponent(fileName)
        try Paths.fm.moveItem(at: downloaded, to: out)
        let expires = (result["expires"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let signedApp = SignedApp(id: UUID(), libraryID: app.id, name: finalName, bundleID: result["bundle_id"] as? String ?? "",
                                  version: finalVersion, certificateName: c.nickname, signedAt: Date(), ipaFile: fileName,
                                  size: RemoteSigner.fileSize(out), tweaks: tweaks.map { $0.lastPathComponent },
                                  viaAppleID: c.fromAppleID, container: opts.container ? true : nil,
                                  remoteManifest: result["manifest_url"] as? String, remoteExpires: expires)
        signed.insert(signedApp, at: 0)
        save()
        if signedApp.viaAppleID == true { AppState.remindBeforeExpiry(signedApp) }
        return signedApp
    }

    private func waitForJob(_ id: String, settings: AppSettings, serverStart: Double,
                            progress: @escaping @MainActor (Double, String) -> Void) async throws -> [String: Any] {
        var failures = 0
        while true {
            try await Task.sleep(nanoseconds: 800_000_000)
            let r: RemoteSigner.Response
            do {
                r = try await RemoteSigner.request("GET", "/jobs/\(id)", settings: settings)
                failures = 0
            } catch let e as URLError {
                failures += 1
                if failures > 15 { throw e }
                continue
            }
            guard r.status == 200 else { throw SayoError(r.json["error"] as? String ?? "HTTP \(r.status)") }
            let state = r.json["state"] as? String ?? ""
            let f = (r.json["progress"] as? NSNumber)?.doubleValue ?? 0
            let stage = state == "queued" ? "queued" : (r.json["stage"] as? String ?? "")
            progress(serverStart + (0.9 - serverStart) * f, stage)
            if state == "done" || state == "error" || state == "expired" || state == "deleted" { return r.json }
        }
    }
}
