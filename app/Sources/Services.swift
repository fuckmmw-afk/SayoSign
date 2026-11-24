import Foundation
import Security
import UIKit

enum Keychain {
    static let service = "dev.murk.sayosign"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, UIImage>()

    func icon(appDir: URL, key: String) -> UIImage? {
        if let c = cache.object(forKey: key as NSString) { return c }
        guard let img = IconCache.find(appDir) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }

    static func find(_ appDir: URL) -> UIImage? {
        let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        var names: [String] = []
        for k in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[k] as? [String: Any], let prim = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += prim["CFBundleIconFiles"] as? [String] ?? []
                if let n = prim["CFBundleIconName"] as? String { names.append(n) }
            }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let f = info["CFBundleIconFile"] as? String { names.append(f) }
        names.append("AppIcon")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: appDir.path)) ?? []
        var best: (UIImage, CGFloat)?
        for n in names {
            let base = n.replacingOccurrences(of: ".png", with: "")
            for f in files where f.hasPrefix(base) && f.lowercased().hasSuffix(".png") {
                if let img = UIImage(contentsOfFile: appDir.appendingPathComponent(f).path) {
                    let s = img.size.width * img.scale
                    if best == nil || s > best!.1 { best = (img, s) }
                }
            }
        }
        return best?.0
    }
}

/// Downloads run in a background URLSession: they go on while SayoSign is in the background
/// (or even closed), and a file that finishes while nobody waits for it is kept and handled
/// at the next launch (see AppState.processPendingDownloads).
final class Downloader: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloader()
    static let identifier = "dev.murk.sayosign.downloads"

    /// Given by iOS when it wakes SayoSign for finished background downloads.
    var backgroundCompletion: (() -> Void)?

    private struct Waiter {
        let continuation: CheckedContinuation<URL, Error>
        let progress: (Double) -> Void
    }
    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Downloader.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.httpAdditionalHeaders = ["User-Agent": "SayoSign/1.0"]
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// `tag` says what the file is for if SayoSign was closed meanwhile: "ipa|<name>|<host>" or "tweak|<identifier>".
    static func download(_ url: URL, tag: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await shared.start(url, tag: tag, progress: progress)
    }

    private func start(_ url: URL, tag: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            var req = URLRequest(url: url)
            req.setValue("SayoSign/1.0", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: req)
            task.taskDescription = tag
            lock.lock()
            waiters[task.taskIdentifier] = Waiter(continuation: c, progress: progress)
            lock.unlock()
            task.resume()
        }
    }

    private func take(_ id: Int) -> Waiter? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: id)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let w = waiters[downloadTask.taskIdentifier]
        lock.unlock()
        w?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let waiter = take(downloadTask.taskIdentifier)
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            waiter?.continuation.resume(throwing: SayoError("HTTP \(http.statusCode)"))
            return
        }
        // The file at `location` is deleted when this method returns.
        let dir = waiter == nil ? PendingDownloads.dir : Paths.work
        let dst = dir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dst)
        } catch {
            waiter?.continuation.resume(throwing: error)
            return
        }
        if let w = waiter {
            w.continuation.resume(returning: dst)
        } else {
            PendingDownloads.add(file: dst.lastPathComponent, tag: downloadTask.taskDescription ?? "")
            Task { @MainActor in await AppState.shared.processPendingDownloads() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { take(task.taskIdentifier)?.continuation.resume(throwing: e) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Files that finished downloading while SayoSign was not waiting for them.
enum PendingDownloads {
    static let key = "pendingDownloads"
    static var dir: URL { Paths.dir("Pending") }

    static func add(file: String, tag: String) {
        let d = UserDefaults.standard
        var list = d.array(forKey: key) as? [[String: String]] ?? []
        list.append(["file": file, "tag": tag])
        d.set(list, forKey: key)
    }

    static func takeAll() -> [(file: URL, tag: String)] {
        let d = UserDefaults.standard
        let list = d.array(forKey: key) as? [[String: String]] ?? []
        d.removeObject(forKey: key)
        return list.compactMap { e in
            guard let f = e["file"] else { return nil }
            return (dir.appendingPathComponent(f), e["tag"] ?? "")
        }
    }
}

enum RepoParser {
    static func fetch(_ url: URL, id: UUID) async throws -> RepoSource {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("SayoSign/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw SayoError("HTTP \(h.statusCode)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw SayoError(L("This source is not valid JSON")) }
        return parse(json, url: url, id: id)
    }

    static func str(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
        }
        return ""
    }

    static func int(_ d: [String: Any], _ keys: [String]) -> Int64 {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.int64Value }
            if let s = d[k] as? String, let v = Int64(s) { return v }
        }
        return 0
    }

    static let tweakExtensions: Set<String> = ["dylib", "deb"]

    static func isTweakURL(_ s: String) -> Bool {
        guard let u = URL(string: s) else { return false }
        return tweakExtensions.contains(u.pathExtension.lowercased())
    }

    static func strings(_ d: [String: Any], _ keys: [String]) -> [String] {
        for k in keys {
            if let a = d[k] as? [String], !a.isEmpty { return a }
            if let s = d[k] as? String, !s.isEmpty {
                return s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            }
        }
        return []
    }

    static func parseTweak(_ t: [String: Any], sourceID: UUID, defaultTargets: [String]) -> RepoTweak? {
        let versions = t["versions"] as? [[String: Any]] ?? []
        let latest = versions.first ?? [:]
        var download = str(latest, ["downloadURL", "down"])
        if download.isEmpty { download = str(t, ["downloadURL", "down", "download", "url", "link"]) }
        if download.isEmpty { return nil }
        let name = str(t, ["name", "Name"])
        var ident = str(t, ["identifier", "bundleIdentifier", "bundleID", "bundleId", "package", "id"])
        if ident.isEmpty { ident = name.isEmpty ? (URL(string: download)?.lastPathComponent ?? download) : name.lowercased() }
        var version = str(latest, ["version"])
        if version.isEmpty { version = str(t, ["version", "Version"]) }
        var date = str(latest, ["date"])
        if date.isEmpty { date = str(t, ["versionDate", "date"]) }
        var desc = str(t, ["localizedDescription", "description", "versionDescription", "subtitle"])
        if desc.isEmpty { desc = str(latest, ["localizedDescription"]) }
        var size = int(latest, ["size"])
        if size == 0 { size = int(t, ["size"]) }
        var targets = strings(t, ["targets", "targetBundleIDs", "targetBundleIdentifiers", "bundleIDs", "for", "target"])
        if targets.isEmpty { targets = defaultTargets }
        return RepoTweak(sourceID: sourceID, identifier: ident,
                         name: name.isEmpty ? (URL(string: download)?.deletingPathExtension().lastPathComponent ?? ident) : name,
                         developer: str(t, ["developerName", "dev", "developer", "author"]),
                         description: desc, iconURL: str(t, ["iconURL", "icon", "iconUrl"]),
                         version: version, date: date, downloadURL: download, size: size, targets: targets)
    }

    static func parse(_ json: Any, url: URL, id: UUID) -> RepoSource {
        var root: [String: Any] = [:]
        var appsRaw: [[String: Any]] = []
        if let d = json as? [String: Any] {
            root = d
            if let a = d["apps"] as? [[String: Any]] { appsRaw = a }
            else if let a = d["Apps"] as? [[String: Any]] { appsRaw = a }
            else {
                for (k, v) in d where !["META", "tweaks", "Tweaks", "news"].contains(k) {
                    if let a = v as? [[String: Any]] { appsRaw += a }
                }
            }
        } else if let a = json as? [[String: Any]] {
            appsRaw = a
        }
        let meta = root["META"] as? [String: Any] ?? [:]
        let name = str(root, ["name", "Name"]).isEmpty ? (str(meta, ["repoName", "name"]).isEmpty ? (url.host ?? "Source") : str(meta, ["repoName", "name"])) : str(root, ["name", "Name"])
        var apps: [RepoApp] = []
        var tweaks: [RepoTweak] = []
        for t in (root["tweaks"] as? [[String: Any]]) ?? (root["Tweaks"] as? [[String: Any]]) ?? [] {
            if let tw = parseTweak(t, sourceID: id, defaultTargets: []) { tweaks.append(tw) }
        }
        for a in appsRaw {
            let versions = a["versions"] as? [[String: Any]] ?? []
            let latest = versions.first ?? [:]
            var download = str(latest, ["downloadURL", "down"])
            if download.isEmpty { download = str(a, ["downloadURL", "down", "download", "url", "link"]) }
            if download.isEmpty { continue }
            let bundleID = str(a, ["bundleIdentifier", "bundleID", "bundleId"])
            // An entry whose file is a .dylib/.deb (or marked as a tweak) is a tweak, not an app.
            let kind = str(a, ["type", "kind"]).lowercased()
            if isTweakURL(download) || kind == "tweak" || kind == "dylib" {
                if let tw = parseTweak(a, sourceID: id, defaultTargets: []) { tweaks.append(tw) }
                continue
            }
            for t in (a["tweaks"] as? [[String: Any]]) ?? [] {
                if let tw = parseTweak(t, sourceID: id, defaultTargets: bundleID.isEmpty ? [] : [bundleID]) { tweaks.append(tw) }
            }
            var version = str(latest, ["version"])
            if version.isEmpty { version = str(a, ["version", "Version"]) }
            var date = str(latest, ["date"])
            if date.isEmpty { date = str(a, ["versionDate", "date"]) }
            var desc = str(a, ["localizedDescription", "description", "versionDescription", "subtitle"])
            if desc.isEmpty { desc = str(latest, ["localizedDescription"]) }
            var size = int(latest, ["size"])
            if size == 0 { size = int(a, ["size"]) }
            let shots = (a["screenshotURLs"] as? [String]) ?? ((a["screenshots"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["imageURL"] as? String) } ?? [])
            apps.append(RepoApp(sourceID: id, name: str(a, ["name", "Name"]),
                                bundleID: bundleID,
                                developer: str(a, ["developerName", "dev", "developer"]),
                                subtitle: str(a, ["subtitle"]), description: desc,
                                iconURL: str(a, ["iconURL", "icon", "iconUrl"]),
                                version: version, date: date, downloadURL: download, size: size,
                                tint: a["tintColor"] as? String, screenshots: shots))
        }
        // One entry per identifier: the first listing wins.
        var seen = Set<String>()
        tweaks = tweaks.filter { seen.insert($0.identifier).inserted }
        return RepoSource(id: id, url: url.absoluteString, name: name, iconURL: str(root, ["iconURL", "icon"]),
                          lastRefresh: Date(), apps: apps, tweaks: tweaks)
    }
}

final class CertificateImportCoordinator: ObservableObject {
    static let shared = CertificateImportCoordinator()
    @Published var p12: URL?
    @Published var profile: URL?
    @Published var presented = false

    func receive(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let dst = Paths.work.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: url, to: dst)
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.main.async {
            if url.pathExtension.lowercased() == "mobileprovision" { self.profile = dst } else { self.p12 = dst }
            self.presented = true
        }
    }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
