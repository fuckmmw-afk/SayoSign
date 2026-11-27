import Foundation
import SwiftUI

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

struct LibraryApp: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minOS: String
    var size: Int64
    var added: Date
    var source: String
    var appFolder: String
    var hasPlugins: Bool
    var encrypted: Bool
    /// Where the IPA was downloaded from, so the signing server can fetch it itself.
    var originURL: String? = nil
    /// SHA-256 of this app packed as an IPA, as uploaded to the signing server: the next signing
    /// asks the server for it by checksum instead of packing and uploading it again.
    var remoteSHA: String? = nil
}

struct SignedApp: Codable, Identifiable, Hashable {
    var id: UUID
    var libraryID: UUID?
    var name: String
    var bundleID: String
    var version: String
    var certificateName: String
    var signedAt: Date
    var ipaFile: String
    var size: Int64
    var tweaks: [String]
    /// Signed with an Apple ID certificate (free profiles need the pairing install path).
    var viaAppleID: Bool? = nil
    /// Prepared to run inside SayoSign (LiveContainer-style), not to be installed.
    var container: Bool? = nil
    /// Signed on the signing server: its manifest installs the app straight from there until it expires.
    var remoteManifest: String? = nil
    var remoteExpires: Date? = nil

    var remoteInstallURL: URL? {
        guard let m = remoteManifest, let e = remoteExpires, e > Date().addingTimeInterval(120) else { return nil }
        let enc = m.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? m
        return URL(string: "itms-services://?action=download-manifest&url=" + enc)
    }
}

struct StoredCertificate: Codable, Identifiable, Hashable {
    var id: UUID
    var nickname: String
    var details: CertDetails
    var profile: ProfileDetails
    var p12File: String
    var profileFile: String
    var added: Date
    var ocsp: OCSPStatus
    var ocspChecked: Date?
    var revokedAt: Date?
    var fromAppleID: Bool

    var expires: Date { min(details.notAfter, profile.expiration) }
    var daysLeft: Int { max(0, Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0) }
    var isExpired: Bool { expires < Date() }
}

struct RepoSource: Codable, Identifiable, Hashable {
    var id: UUID
    var url: String
    var name: String
    var iconURL: String?
    var lastRefresh: Date?
    var apps: [RepoApp]
    /// Tweaks (.dylib / .deb) the source lists. Optional so older saved state still decodes.
    var tweaks: [RepoTweak]? = nil
}

/// A tweak offered by a source: a top-level `tweaks` entry, an app's own `tweaks` entry,
/// or an `apps` entry whose download is a .dylib or .deb.
struct RepoTweak: Codable, Identifiable, Hashable {
    var id: String { sourceID.uuidString + "|" + identifier }
    var sourceID: UUID
    var identifier: String
    var name: String
    var developer: String
    var description: String
    var iconURL: String
    var version: String
    var date: String
    var downloadURL: String
    var size: Int64
    /// Bundle IDs of the apps this tweak is meant for ("*" = any app).
    var targets: [String]

    func fits(_ bundleID: String) -> Bool {
        targets.contains { $0 == "*" || $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// A tweak downloaded from a source; SayoSign keeps it up to date and attaches it when signing its apps.
struct InstalledTweak: Codable, Identifiable, Hashable {
    var id: String { identifier }
    var identifier: String
    var sourceID: UUID
    var name: String
    var version: String
    /// File name inside Paths.tweaks.
    var file: String
    var downloadURL: String
    var targets: [String]
    var autoUpdate: Bool
    var updated: Date

    func fits(_ bundleID: String) -> Bool {
        targets.contains { $0 == "*" || $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

struct RepoApp: Codable, Identifiable, Hashable {
    var id: String { sourceID.uuidString + "|" + bundleID + "|" + version + "|" + downloadURL }
    var sourceID: UUID
    var name: String
    var bundleID: String
    var developer: String
    var subtitle: String
    var description: String
    var iconURL: String
    var version: String
    var date: String
    var downloadURL: String
    var size: Int64
    var tint: String?
    var screenshots: [String]
}

struct AppSettings: Codable, Equatable {
    var selectedCertificate: UUID?
    var compressionLevel: Int = 1
    var autoRemovePlugins = false
    var removeWatchApps = true
    var deleteAfterInstall = false
    var serverPort: Int = 47616
    var anisetteURL = Anisette.defaultServer
    var bundleSuffix = ""
    var keepAliveAudio = true
    var udid = ""
    var appleIDTeam = ""
    /// 0 = follow the system, 1 = light, 2 = black.
    var appearance = 0
    /// Manifest service (a Cloudflare Worker) for installing without the local CA profile.
    /// Empty: use the on-device HTTPS server and its one-time profile.
    var manifestService = AppSettings.defaultManifestService
    /// 0 = automatic (pairing for Apple ID apps when paired), 1 = over the air, 2 = pairing.
    var installMethod = 0
    /// LocalDevVPN's address of this iPhone.
    var tunnelAddress = "10.7.0.1"
    /// Download new versions of tweaks taken from sources whenever sources refresh.
    var autoUpdateTweaks = true
    /// Pre-select a source tweak when signing an app it targets, and fetch it with that app.
    var autoAttachTweaks = true
    /// Sign on the signing server instead of this iPhone by default.
    var remoteSigning = false
    /// Signing server; its key is kept in the Keychain (RemoteSigner.key).
    var remoteServer = AppSettings.defaultRemoteServer
    static let defaultRemoteServer = "https://fuckmmw.space/sign"
    static let defaultManifestService = "https://sayosign.afk9659-0de.workers.dev"

    init() {}

    // Decoding field by field keeps older saved settings (and the whole library) readable
    // when new fields are added, instead of failing and resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedCertificate = (try? c.decodeIfPresent(UUID.self, forKey: .selectedCertificate)) ?? nil
        compressionLevel = (try? c.decodeIfPresent(Int.self, forKey: .compressionLevel)) ?? d.compressionLevel
        autoRemovePlugins = (try? c.decodeIfPresent(Bool.self, forKey: .autoRemovePlugins)) ?? d.autoRemovePlugins
        removeWatchApps = (try? c.decodeIfPresent(Bool.self, forKey: .removeWatchApps)) ?? d.removeWatchApps
        deleteAfterInstall = (try? c.decodeIfPresent(Bool.self, forKey: .deleteAfterInstall)) ?? d.deleteAfterInstall
        serverPort = (try? c.decodeIfPresent(Int.self, forKey: .serverPort)) ?? d.serverPort
        anisetteURL = (try? c.decodeIfPresent(String.self, forKey: .anisetteURL)) ?? d.anisetteURL
        bundleSuffix = (try? c.decodeIfPresent(String.self, forKey: .bundleSuffix)) ?? d.bundleSuffix
        keepAliveAudio = (try? c.decodeIfPresent(Bool.self, forKey: .keepAliveAudio)) ?? d.keepAliveAudio
        udid = (try? c.decodeIfPresent(String.self, forKey: .udid)) ?? d.udid
        appleIDTeam = (try? c.decodeIfPresent(String.self, forKey: .appleIDTeam)) ?? d.appleIDTeam
        appearance = (try? c.decodeIfPresent(Int.self, forKey: .appearance)) ?? d.appearance
        manifestService = (try? c.decodeIfPresent(String.self, forKey: .manifestService)) ?? d.manifestService
        installMethod = (try? c.decodeIfPresent(Int.self, forKey: .installMethod)) ?? d.installMethod
        tunnelAddress = (try? c.decodeIfPresent(String.self, forKey: .tunnelAddress)) ?? d.tunnelAddress
        autoUpdateTweaks = (try? c.decodeIfPresent(Bool.self, forKey: .autoUpdateTweaks)) ?? d.autoUpdateTweaks
        autoAttachTweaks = (try? c.decodeIfPresent(Bool.self, forKey: .autoAttachTweaks)) ?? d.autoAttachTweaks
        remoteSigning = (try? c.decodeIfPresent(Bool.self, forKey: .remoteSigning)) ?? d.remoteSigning
        remoteServer = (try? c.decodeIfPresent(String.self, forKey: .remoteServer)) ?? d.remoteServer
        // Servers Apple now rejects are switched to a working one.
        if Anisette.rejectedServers.contains(anisetteURL) || anisetteURL.trimmingCharacters(in: .whitespaces).isEmpty {
            anisetteURL = Anisette.defaultServer
        }
    }
}

struct DownloadTask: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var progress: Double
    var status: String
}
