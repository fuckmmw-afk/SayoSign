import Foundation
import UIKit
import UserNotifications

/// Tweaks pulled from sources: download, keep up to date, attach when signing.
extension AppState {
    var allRepoTweaks: [RepoTweak] { sources.flatMap { $0.tweaks ?? [] } }

    func installed(_ t: RepoTweak) -> InstalledTweak? {
        installedTweaks.first { $0.identifier == t.identifier }
    }

    func installed(file: URL) -> InstalledTweak? {
        installedTweaks.first { $0.file == file.lastPathComponent }
    }

    /// The source listing for an installed tweak: its own source first, then any other source with the same identifier.
    func latest(for i: InstalledTweak) -> RepoTweak? {
        let all = allRepoTweaks.filter { $0.identifier == i.identifier }
        return all.first { $0.sourceID == i.sourceID } ?? all.first
    }

    func hasUpdate(_ i: InstalledTweak) -> Bool {
        guard let l = latest(for: i) else { return false }
        return l.version != i.version || l.downloadURL != i.downloadURL
    }

    func tweakURL(_ i: InstalledTweak) -> URL { Paths.tweaks.appendingPathComponent(i.file) }

    /// Downloaded source tweaks meant for this bundle ID.
    func tweakFiles(for bundleID: String) -> [URL] {
        installedTweaks.filter { $0.fits(bundleID) }.map(tweakURL).filter { Paths.fm.fileExists(atPath: $0.path) }
    }

    /// The file name a source tweak is saved under: the link's name without a "-<version>" suffix,
    /// so the name inside the app stays the same from version to version.
    func tweakFileName(_ t: RepoTweak, ext: String) -> String {
        let url = URL(string: t.downloadURL)
        var base = url?.deletingPathExtension().lastPathComponent ?? ""
        if base.isEmpty || base == "/" { base = t.name }
        base = base.replacingOccurrences(of: "/", with: "-")
        if !t.version.isEmpty, base.count > t.version.count + 1, base.hasSuffix("-" + t.version) {
            base = String(base.dropLast(t.version.count + 1))
        }
        return base + "." + ext
    }

    /// Expected file name before the download (the extension of the link, else .dylib).
    func expectedFileName(_ t: RepoTweak) -> String {
        if let i = installed(t) { return i.file }
        let ext = URL(string: t.downloadURL)?.pathExtension.lowercased() ?? ""
        return tweakFileName(t, ext: ext == "deb" ? "deb" : "dylib")
    }

    /// Downloads (or re-downloads) a tweak from its source into the saved tweaks.
    @discardableResult
    func installTweak(_ t: RepoTweak, quiet: Bool = false) async -> Bool {
        guard let url = URL(string: t.downloadURL) else { if !quiet { show(L("Invalid URL")) }; return false }
        if !quiet { AppState.askForNotifications() }
        let task = DownloadTask(name: t.name, progress: 0, status: L("Downloading"))
        downloads.append(task)
        let tid = task.id
        defer { downloads.removeAll { $0.id == tid } }
        do {
            let file = try await Downloader.download(url, tag: "tweak|" + t.identifier) { f in
                Task { @MainActor in
                    if let i = AppState.shared.downloads.firstIndex(where: { $0.id == tid }) {
                        AppState.shared.downloads[i].progress = f
                    }
                }
            }
            defer { try? Paths.fm.removeItem(at: file) }
            let name = try finishTweak(file, t)
            if !quiet { show(LF("Saved tweak %@", name)) }
            return true
        } catch {
            show(error.localizedDescription)
            return false
        }
    }

    /// Puts a downloaded file in place of the tweak's previous version and drops older copies.
    @discardableResult
    func finishTweak(_ file: URL, _ t: RepoTweak) throws -> String {
        guard let ext = AppState.tweakKind(file) else {
            throw SayoError(LF("%@ is not a .dylib or .deb", t.name))
        }
        let fileName = tweakFileName(t, ext: ext)
        let dst = Paths.tweaks.appendingPathComponent(fileName)
        let previous = installed(t)
        try? Paths.fm.removeItem(at: dst)
        try Paths.fm.moveItem(at: file, to: dst)
        if let p = previous, p.file != fileName { try? Paths.fm.removeItem(at: tweakURL(p)) }
        removeOlderCopies(of: fileName)
        let record = InstalledTweak(identifier: t.identifier, sourceID: t.sourceID, name: t.name, version: t.version,
                                    file: fileName, downloadURL: t.downloadURL, targets: t.targets,
                                    autoUpdate: previous?.autoUpdate ?? true, updated: Date())
        installedTweaks.removeAll { $0.identifier == t.identifier || $0.file == fileName }
        installedTweaks.append(record)
        save()
        return fileName
    }

    /// "Aura-0.4.3-7bb4993.dylib", "Aura 0.4.2.dylib" and "aura.dylib" are all "aura".
    nonisolated static func tweakStem(_ fileName: String) -> String {
        var s = (fileName as NSString).deletingPathExtension.lowercased()
        if let r = s.range(of: #"[-_ ]v?\d+(\.\d+)*([-_.][0-9a-z]+)*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
    }

    /// After a new version lands: deletes saved files that are older copies of the same tweak
    /// (other versions of its name), unless another source tweak owns them.
    func removeOlderCopies(of fileName: String) {
        let stem = AppState.tweakStem(fileName)
        let ext = (fileName as NSString).pathExtension.lowercased()
        let owned = Set(installedTweaks.map { $0.file })
        let files = (try? Paths.fm.contentsOfDirectory(atPath: Paths.tweaks.path)) ?? []
        for f in files where f != fileName && !owned.contains(f) {
            if (f as NSString).pathExtension.lowercased() == ext, AppState.tweakStem(f) == stem {
                try? Paths.fm.removeItem(at: Paths.tweaks.appendingPathComponent(f))
            }
        }
    }

    static func askForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A toast in the app; a notification when the update happened in the background.
    func notifyTweaksUpdated(_ names: [String]) {
        guard !names.isEmpty else { return }
        let text = LF("Tweaks updated: %@", names.joined(separator: ", "))
        if UIApplication.shared.applicationState == .active {
            show(text)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = L("Tweaks updated")
        content.body = names.joined(separator: ", ")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "tweaks." + UUID().uuidString, content: content, trigger: nil))
    }

    func removeTweak(_ i: InstalledTweak) {
        try? Paths.fm.removeItem(at: tweakURL(i))
        installedTweaks.removeAll { $0.identifier == i.identifier }
        save()
    }

    func setAutoUpdate(_ i: InstalledTweak, _ on: Bool) {
        if let k = installedTweaks.firstIndex(where: { $0.identifier == i.identifier }) {
            installedTweaks[k].autoUpdate = on
            save()
        }
    }

    /// Fetches newer versions of every auto-updating source tweak.
    func updateTweaks() async {
        var updated: [String] = []
        for i in installedTweaks where i.autoUpdate && hasUpdate(i) {
            if let l = latest(for: i), await installTweak(l, quiet: true) {
                updated.append(l.version.isEmpty ? l.name : "\(l.name) \(l.version)")
            }
        }
        notifyTweaksUpdated(updated)
    }

    /// Called when the app becomes active: refreshes sources (and so tweaks) at most every 30 minutes.
    func autoRefreshTweaks() async {
        guard settings.autoUpdateTweaks, !installedTweaks.isEmpty, !sources.isEmpty else { return }
        if let last = lastTweakCheck, Date().timeIntervalSince(last) < 1800 { return }
        lastTweakCheck = Date()
        await refreshSources()
    }

    /// Gets an app from a source, together with that source's tweaks for it.
    func get(_ app: RepoApp) async {
        guard let u = URL(string: app.downloadURL) else { show(L("Invalid URL")); return }
        if settings.autoAttachTweaks, !app.bundleID.isEmpty {
            let wanted = (sources.first { $0.id == app.sourceID }?.tweaks ?? []).filter { $0.fits(app.bundleID) && !$0.targets.contains("*") }
            for t in wanted {
                if let i = installed(t), !hasUpdate(i) { continue }
                await installTweak(t, quiet: true)
            }
        }
        await download(u, name: app.name)
    }

    /// "dylib" or "deb" judged by the file's first bytes (a server's error page is neither).
    nonisolated static func tweakKind(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        if b.count >= 7, String(bytes: b[0..<7], encoding: .ascii) == "!<arch>" { return "deb" }
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let machO: Set<UInt32> = [0xcffaedfe, 0xcefaedfe, 0xfeedfacf, 0xfeedface, 0xcafebabe, 0xbebafeca]
        return machO.contains(magic) ? "dylib" : nil
    }
}
