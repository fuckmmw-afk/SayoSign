import Foundation

/// A tweak already built into an app (by ESign, Feather, SayoSign...): a .dylib in Frameworks
/// or a hooking framework the main executable loads.
struct EmbeddedTweak: Identifiable, Hashable {
    var id: String { name }
    /// File name inside Frameworks ("x.dylib" or "CydiaSubstrate.framework").
    var name: String
    var size: Int64
    /// The main executable loads it; otherwise only another tweak does.
    var loaded: Bool
    var isFramework: Bool { name.hasSuffix(".framework") }
}

enum Embedded {
    static let hookFrameworks: Set<String> = ["cydiasubstrate.framework", "ellekit.framework", "libhooker.framework",
                                              "substitute.framework", "orion.framework", "cephei.framework",
                                              "cepheiui.framework", "cepheiprefs.framework", "altlist.framework",
                                              "alderis.framework"]

    static func executable(_ bundle: URL) -> URL? {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        guard let exe = info["CFBundleExecutable"] as? String else { return nil }
        return bundle.appendingPathComponent(exe)
    }

    /// The app and its extensions: every bundle whose executable may load tweaks.
    static func bundles(_ app: URL) -> [URL] {
        var out = [app]
        for dir in ["PlugIns", "Extensions"] {
            let d = app.appendingPathComponent(dir)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".appex") {
                out.append(d.appendingPathComponent(f))
            }
        }
        return out
    }

    static func isTweakName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasSuffix(".dylib") { return !n.hasPrefix("libswift") }
        return hookFrameworks.contains(n)
    }

    /// Name in Frameworks for a load path like @rpath/x.dylib or @executable_path/Frameworks/X.framework/X.
    static func frameworksName(_ path: String) -> String? {
        guard path.hasPrefix("@") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        if let fw = parts.first(where: { $0.hasSuffix(".framework") }) { return fw }
        return parts.last
    }

    static func scan(app: URL) -> [EmbeddedTweak] {
        let fm = FileManager.default
        let frameworks = app.appendingPathComponent("Frameworks")
        var loaded = Set<String>()
        if let exe = executable(app) {
            for p in SayoCore.loadPaths(exe) {
                if let n = frameworksName(p), isTweakName(n) { loaded.insert(n) }
            }
        }
        var names = loaded
        for f in (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? [] where isTweakName(f) { names.insert(f) }
        return names.compactMap { n in
            let u = frameworks.appendingPathComponent(n)
            guard fm.fileExists(atPath: u.path) || loaded.contains(n) else { return nil }
            let size = n.hasSuffix(".framework") ? AppState.folderSize(u)
                : Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return EmbeddedTweak(name: n, size: size, loaded: loaded.contains(n))
        }
        .sorted { ($0.isFramework ? 1 : 0, $0.name.lowercased()) < ($1.isFramework ? 1 : 0, $1.name.lowercased()) }
    }

    /// Takes tweaks out of an app copy: their load commands in the app and its extensions, and their files.
    static func remove(_ names: [String], from app: URL) throws {
        guard !names.isEmpty else { return }
        let fm = FileManager.default
        for b in bundles(app) {
            if let exe = executable(b), fm.fileExists(atPath: exe.path) {
                for n in names { try SayoCore.removeDylib(exe, name: n) }
            }
            for n in names { try? fm.removeItem(at: b.appendingPathComponent("Frameworks").appendingPathComponent(n)) }
        }
    }
}
