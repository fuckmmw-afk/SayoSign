import SwiftUI
import UniformTypeIdentifiers

struct SignView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let app: LibraryApp

    @State private var name = ""
    @State private var bundleID = ""
    /// With an explicit-ID .p12 profile: keep each app's own bundle ID (like other signers do).
    @State private var keepOwnID = true
    @State private var version = ""
    @State private var minIOS = ""
    @State private var iconURL: URL?
    @State private var iconImage: UIImage?
    @State private var tweaks: [URL] = []
    @State private var entitlements: URL?
    @State private var removePlugins = false
    @State private var removeWatch = true
    @State private var removeSchemes = false
    @State private var fileSharing = false
    @State private var inside = false
    @State private var certID: UUID?
    @State private var progress: Double = 0
    @State private var stage = ""
    @State private var signing = false
    @State private var done: SignedApp?
    @State private var error: String?
    @State private var setup = false
    @State private var attached = false
    /// Identifiers of source tweaks to build in (their files can change name on update).
    @State private var picked: Set<String> = []
    @State private var tweakBusy: Set<String> = []
    @State private var checking = false
    @State private var allSourceTweaks = false
    /// Tweaks already built into the app, what to take out and what to swap for another file.
    @State private var embedded: [EmbeddedTweak] = []
    @State private var dropEmbedded: Set<String> = []
    @State private var replacements: [String: URL] = [:]
    @State private var replacing: String?
    /// Sign on the signing server instead of this iPhone.
    @State private var onServer = false
    @State private var remote = false

    enum PickKind: Identifiable {
        case icon, tweak, entitlements, replace
        var id: Int { hashValue }
    }

    var cert: StoredCertificate? {
        if let id = certID { return state.certificates.first { $0.id == id } }
        return state.selectedCertificate
    }

    /// The profile's single bundle ID for an explicit .p12 profile (Apple ID profiles are made per app).
    var explicitBundle: String? {
        guard let c = cert, !c.fromAppleID, !c.profile.isWildcard else { return nil }
        return c.profile.bundleID
    }

    var forcedBundle: String? { keepOwnID ? nil : explicitBundle }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Button { pick(.icon) } label: {
                            ZStack(alignment: .bottomTrailing) {
                                AppIconView(image: iconImage ?? state.icon(for: app), size: 66)
                                Image(systemName: "pencil.circle.fill").font(.title3).foregroundColor(Theme.rose).background(Circle().fill(Color.white))
                            }
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title3.weight(.bold))
                            Text("\(app.bundleID) · v\(app.version)").font(.caption).foregroundColor(.secondary)
                            if app.encrypted {
                                Text(L("This IPA is encrypted and will not run. Use a decrypted IPA.")).font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text(L("Certificate"))) {
                    if state.certificates.isEmpty {
                        Button(L("Add a certificate first")) { dismiss(); state.tab = 1 }
                    } else {
                        Picker(L("Certificate"), selection: Binding(get: { cert?.id }, set: { certID = $0 })) {
                            ForEach(state.certificates) { c in
                                Text(c.nickname).tag(Optional(c.id))
                            }
                        }
                        if let c = cert {
                            HStack {
                                StatusDot(status: c.ocsp, expired: c.isExpired)
                                Spacer()
                                Text(c.profile.isWildcard ? L("Wildcard profile") : c.profile.bundleID).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text(L("App")), footer: explicitBundle.map { fb in
                    Text(keepOwnID
                         ? LF("This profile is made for %@. The app keeps its own bundle ID, so several apps can be installed side by side; app extensions are removed.", fb)
                         : LF("This profile only allows %@, the bundle ID will be replaced and app extensions removed.", fb)
                           + (fb.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
                              ? "\n\n⚠️ " + L("SayoSign itself has this bundle ID. An app signed with this certificate cannot be installed while SayoSign uses the same ID.")
                              : ""))
                }) {
                    if explicitBundle != nil {
                        Toggle(L("Keep the app's own bundle ID"), isOn: $keepOwnID)
                    }
                    LabeledField(title: L("Name"), text: $name, placeholder: app.name)
                    LabeledField(title: L("Bundle ID"), text: $bundleID, placeholder: forcedBundle ?? app.bundleID)
                        .disabled(forcedBundle != nil)
                    LabeledField(title: L("Version"), text: $version, placeholder: app.version)
                    LabeledField(title: L("Minimum iOS"), text: $minIOS, placeholder: app.minOS)
                }

                if !embedded.isEmpty {
                    embeddedSection
                }
                if !sourceItems.isEmpty || !state.allRepoTweaks.isEmpty {
                    sourceTweaksSection
                }

                Section(header: Text(L("Tweaks")), footer: Text(L("Supports .dylib, .deb and .framework. Substrate, ElleKit and libhooker tweaks are wired to SayoHook automatically."))) {
                    ForEach(tweaks, id: \.self) { t in
                        HStack {
                            Image(systemName: t.pathExtension == "deb" ? "shippingbox.fill" : "puzzlepiece.extension.fill").foregroundColor(Theme.rose)
                            Text(t.lastPathComponent).lineLimit(1)
                            if let i = state.installed(file: t) {
                                Spacer()
                                Text(i.version.isEmpty ? L("From source") : "v" + i.version).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { tweaks.remove(atOffsets: $0) }
                    let saved = savedTweaks()
                    if !saved.isEmpty {
                        Menu {
                            ForEach(saved, id: \.self) { u in
                                Button(u.lastPathComponent) {
                                if let i = state.installed(file: u) { picked.insert(i.identifier) }
                                else if !tweaks.contains(u) { tweaks.append(u) }
                            }
                            }
                        } label: { Label(L("Add saved tweak"), systemImage: "tray.full") }
                    }
                    Button { pick(.tweak) } label: { Label(L("Add tweak from Files"), systemImage: "plus") }
                }

                Section(header: Text(L("Options"))) {
                    Toggle(L("Remove app extensions"), isOn: $removePlugins)
                    Toggle(L("Remove Apple Watch app"), isOn: $removeWatch)
                    Toggle(L("Remove URL schemes"), isOn: $removeSchemes)
                    Toggle(L("Enable file sharing"), isOn: $fileSharing)
                    Toggle(isOn: $inside) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Run inside SayoSign (experimental)"))
                            Text(L("Like LiveContainer: not installed in iOS, no app limit. Use the same certificate SayoSign itself is signed with."))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Button { pick(.entitlements) } label: {
                        HStack {
                            Text(L("Extra entitlements"))
                            Spacer()
                            Text(entitlements?.lastPathComponent ?? L("None")).foregroundColor(.secondary)
                        }
                    }
                }

                if RemoteSigner.isConfigured(state.settings) || onServer {
                    Section(footer: Text(onServer
                                         ? (app.originURL != nil
                                            ? L("The server downloads this IPA from its source itself, signs it and the app installs straight from the server.")
                                            : L("This IPA is uploaded to the server, signed there and installed straight from the server."))
                                         : L("Signed by this iPhone."))) {
                        Picker(L("Sign on"), selection: $onServer) {
                            Text(L("iPhone")).tag(false)
                            Text(L("Server")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(signing)
                    }
                }

                if signing {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress).tint(Theme.rose)
                            Text(stageName(stage)).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let e = error {
                    Section { Text(e).foregroundColor(.red).font(.callout) }
                }
                if let s = done, s.container == true {
                    Section(footer: Text(L("SayoSign closes; open it again and the app starts inside it. Close that app and open SayoSign again to come back."))) {
                        Button {
                            do { try Container.run(s, ipa: state.ipaURL(s)) } catch { self.error = error.localizedDescription }
                        } label: { Label(L("Run inside SayoSign"), systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .listRowBackground(Color.clear)
                    }
                } else if let s = done {
                    Section {
                        Button {
                            Task {
                                do {
                                    try await Installer.install(s, state: state)
                                    dismiss()
                                } catch is InstallNeedsSetup {
                                    setup = true
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        } label: { Label(L("Install now"), systemImage: "arrow.down.app.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        Button { Task { await sign() } } label: {
                            HStack {
                                if signing { ProgressView().tint(.white) }
                                Text(signing ? L("Signing…") : L("Sign"))
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(signing || cert == nil)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(L("Sign"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
            }
            .sheet(isPresented: $setup) { InstallSetupView().environmentObject(state) }
            .onAppear {
                removePlugins = state.settings.autoRemovePlugins
                removeWatch = state.settings.removeWatchApps
                if !attached { onServer = state.settings.remoteSigning && RemoteSigner.isConfigured(state.settings) }
                if !attached {
                    attached = true
                    let dir = state.appURL(app)
                    Task {
                        let found = await Task.detached(priority: .userInitiated) { Embedded.scan(app: dir) }.value
                        embedded = found
                    }
                    if state.settings.autoAttachTweaks {
                        picked = Set(state.installedTweaks.filter { $0.fits(app.bundleID) }.map { $0.identifier })
                    }
                }
            }
        }
        .interactiveDismissDisabled(signing)
    }

    /// The kind travels with the request, so the result is filed correctly.
    func pick(_ kind: PickKind) {
        let types: [UTType]
        switch kind {
        case .icon: types = [.png, .jpeg, .image]
        case .tweak: types = [.deb, .dylib, .folder, .data]
        case .entitlements: types = [.xml, .propertyList, .data]
        case .replace: types = [.dylib, .data]
        }
        FilePicker.shared.pick(types, multiple: kind == .tweak) { urls in
            for u in urls { take(u, kind: kind) }
        }
    }

    struct SourceItem: Identifiable {
        var id: String
        var repo: RepoTweak?
        var installed: InstalledTweak?
        var name: String { repo?.name ?? installed?.name ?? id }
        var outdated: Bool {
            guard let r = repo, let i = installed else { return false }
            return r.version != i.version || r.downloadURL != i.downloadURL
        }
        func fits(_ bundleID: String) -> Bool { (repo?.fits(bundleID) ?? false) || (installed?.fits(bundleID) ?? false) }
    }

    /// Source tweaks for this app (or all of them), merged with what is already downloaded.
    var sourceItems: [SourceItem] {
        var items: [String: SourceItem] = [:]
        var order: [String] = []
        for i in state.installedTweaks {
            items[i.identifier] = SourceItem(id: i.identifier, repo: state.latest(for: i), installed: i)
            order.append(i.identifier)
        }
        for r in state.allRepoTweaks where items[r.identifier] == nil {
            items[r.identifier] = SourceItem(id: r.identifier, repo: r, installed: nil)
            order.append(r.identifier)
        }
        return order.compactMap { items[$0] }.filter { allSourceTweaks || picked.contains($0.id) || $0.fits(app.bundleID) }
    }

    var sourceTweaksSection: some View {
        let items = sourceItems
        let outdated = items.filter { $0.outdated && $0.repo != nil }
        return Section(header: Text(L("Tweaks from sources")),
                       footer: Text(L("Turn on the tweaks to build into this app. Downloaded tweaks are kept up to date; new versions are fetched here or when sources refresh."))) {
            if items.isEmpty {
                Text(L("No tweaks for this app in your sources")).font(.callout).foregroundColor(.secondary)
            }
            ForEach(items) { item in sourceRow(item) }
            if !outdated.isEmpty {
                Button {
                    Task {
                        for o in outdated { if let r = o.repo { await fetch(r) } }
                    }
                } label: { Label(LF("Update all (%ld)", outdated.count), systemImage: "arrow.down.circle.fill") }
            }
            Button {
                checking = true
                Task {
                    await state.refreshSources()
                    checking = false
                }
            } label: {
                HStack {
                    Label(L("Check for tweak updates"), systemImage: "arrow.triangle.2.circlepath")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(checking)
            Toggle(L("Show tweaks for other apps"), isOn: $allSourceTweaks)
        }
    }

    func sourceRow(_ item: SourceItem) -> some View {
        let busy = tweakBusy.contains(item.id)
        let on = Binding<Bool>(
            get: { picked.contains(item.id) },
            set: { v in
                if !v { picked.remove(item.id); return }
                picked.insert(item.id)
                if item.installed == nil, let r = item.repo { Task { await fetch(r) } }
            })
        return HStack(spacing: 10) {
            Image(systemName: (item.repo?.downloadURL ?? item.installed?.file ?? "").lowercased().hasSuffix(".deb") ? "shippingbox.fill" : "puzzlepiece.extension.fill")
                .foregroundColor(Theme.rose)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Group {
                    if let i = item.installed, item.outdated, let r = item.repo {
                        Text(LF("v%@ → v%@", i.version, r.version)).foregroundColor(.orange)
                    } else if let i = item.installed {
                        Text(i.version.isEmpty ? L("Downloaded") : "v" + i.version + (item.repo == nil ? " · " + L("not in sources") : ""))
                    } else {
                        Text((item.repo.map { $0.version.isEmpty ? "" : "v" + $0.version + " · " } ?? "") + L("not downloaded"))
                    }
                }
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView()
            } else if let r = item.repo, item.installed == nil || item.outdated {
                Button(item.installed == nil ? L("Get") : L("Update")) { Task { await fetch(r) } }
                    .buttonStyle(SmallButtonStyle(filled: false))
            }
            Toggle("", isOn: on).labelsHidden().disabled(busy)
        }
    }

    /// The source tweak saved (or to be saved) under this file name.
    func sourceItem(named name: String) -> SourceItem? {
        let n = name.lowercased()
        let all = state.installedTweaks.map { SourceItem(id: $0.identifier, repo: state.latest(for: $0), installed: $0) }
            + state.allRepoTweaks.filter { state.installed($0) == nil }.map { SourceItem(id: $0.identifier, repo: $0, installed: nil) }
        return all.first { item in
            let file = item.installed?.file ?? item.repo.map { state.expectedFileName($0) } ?? ""
            return file.lowercased() == n
        }
    }

    func unpickSource(matching name: String) {
        if let s = sourceItem(named: name) { picked.remove(s.id) }
    }

    var embeddedSection: some View {
        Section(header: Text(L("Already in the app")),
                footer: Text(L("Tweaks built into this IPA earlier. Turn one off to take it out, or replace it with a newer file or the version from a source."))) {
            ForEach(embedded) { e in embeddedRow(e) }
        }
    }

    func embeddedRow(_ e: EmbeddedTweak) -> some View {
        let source = sourceItem(named: e.name)
        let fromSource = source.map { picked.contains($0.id) } ?? false
        let keep = Binding<Bool>(
            get: { !dropEmbedded.contains(e.name) || replacements[e.name] != nil || fromSource },
            set: { v in
                if v { dropEmbedded.remove(e.name); return }
                dropEmbedded.insert(e.name)
                replacements[e.name] = nil
                unpickSource(matching: e.name)
            })
        return HStack(spacing: 10) {
            Image(systemName: e.isFramework ? "shippingbox" : "puzzlepiece.extension")
                .foregroundColor(keep.wrappedValue ? Theme.rose : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).strikethrough(!keep.wrappedValue).lineLimit(1)
                Group {
                    if replacements[e.name] != nil {
                        Text(L("will be replaced with the chosen file")).foregroundColor(.orange)
                    } else if fromSource, let s = source {
                        Text(LF("will be replaced with %@", s.name + ((s.repo?.version ?? s.installed?.version).map { $0.isEmpty ? "" : " v" + $0 } ?? ""))).foregroundColor(.orange)
                    } else if !keep.wrappedValue {
                        Text(L("will be removed")).foregroundColor(.red)
                    } else if let s = source, let v = s.repo?.version ?? s.installed?.version {
                        Text(formatSize(e.size) + " · " + LF("v%@ in sources", v))
                    } else {
                        Text(formatSize(e.size) + (e.loaded ? "" : " · " + L("loaded by another tweak")))
                    }
                }
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                if let s = source, let r = s.repo {
                    Button {
                        replacements[e.name] = nil
                        dropEmbedded.remove(e.name)
                        picked.insert(s.id)
                        if s.installed == nil || s.outdated { Task { await fetch(r) } }
                    } label: { Label(LF("Replace with %@ from source", r.version.isEmpty ? r.name : "v" + r.version), systemImage: "arrow.down.circle") }
                } else if let s = source, s.installed != nil {
                    Button {
                        replacements[e.name] = nil
                        dropEmbedded.remove(e.name)
                        picked.insert(s.id)
                    } label: { Label(L("Replace with the saved copy"), systemImage: "tray.full") }
                }
                if !e.isFramework {
                    Button {
                        replacing = e.name
                        pick(.replace)
                    } label: { Label(L("Replace with a file…"), systemImage: "doc.badge.plus") }
                }
                if replacements[e.name] != nil || fromSource || dropEmbedded.contains(e.name) {
                    Button {
                        replacements[e.name] = nil
                        dropEmbedded.remove(e.name)
                        unpickSource(matching: e.name)
                    } label: { Label(L("Keep as it is"), systemImage: "arrow.uturn.backward") }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            Toggle("", isOn: keep).labelsHidden()
        }
    }

    func fetch(_ r: RepoTweak) async {
        tweakBusy.insert(r.identifier)
        let ok = await state.installTweak(r, quiet: true)
        tweakBusy.remove(r.identifier)
        if !ok { picked.remove(r.identifier) }
    }

    func savedTweaks() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.tweaks, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func take(_ u: URL, kind: PickKind?) {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        switch kind {
        case .icon:
            if let img = UIImage(contentsOfFile: u.path) ?? (try? Data(contentsOf: u)).flatMap(UIImage.init(data:)) {
                let size = CGSize(width: 180, height: 180)
                let r = UIGraphicsImageRenderer(size: size)
                let out = r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
                let dst = Paths.work.appendingPathComponent("icon-\(UUID().uuidString).png")
                try? out.pngData()?.write(to: dst)
                iconURL = dst
                iconImage = out
            }
        case .tweak:
            let dst = Paths.tweaks.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: u, to: dst)
                if !tweaks.contains(dst) { tweaks.append(dst) }
            } catch {
                self.error = error.localizedDescription
            }
        case .replace:
            guard let name = replacing else { break }
            replacing = nil
            // Saved under the tweak's own name, so it takes the old file's place inside the app.
            let dir = Paths.work.appendingPathComponent("replace-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: u, to: dst)
                guard AppState.tweakKind(dst) == "dylib" else { throw SayoError(LF("%@ is not a .dylib or .deb", u.lastPathComponent)) }
                replacements[name] = dst
                dropEmbedded.remove(name)
                unpickSource(matching: name)
            } catch {
                self.error = error.localizedDescription
            }
        case .entitlements:
            let dst = Paths.work.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: u, to: dst)
            entitlements = dst
        case .none:
            break
        }
    }

    func stageName(_ s: String) -> String {
        if remote { return RemoteSigner.stageName(s) }
        switch s {
        case "copy": return L("Preparing")
        case "prepare": return L("Patching Info.plist")
        case "inject": return L("Injecting tweaks")
        case "sign": return L("Signing binaries")
        case "zip": return L("Packing IPA")
        default: return s
        }
    }

    func sign() async {
        guard let c = cert else { error = L("Choose a certificate"); return }
        error = nil
        signing = true
        progress = 0
        stage = "copy"
        defer { signing = false }
        var opts = SayoCore.SignOptions()
        opts.bundleID = bundleID.trimmingCharacters(in: .whitespaces)
        // An explicit .p12 profile would otherwise rename every app to the profile's ID.
        if opts.bundleID.isEmpty && keepOwnID && explicitBundle != nil { opts.bundleID = app.bundleID }
        opts.displayName = name.trimmingCharacters(in: .whitespaces)
        opts.shortVersion = version.trimmingCharacters(in: .whitespaces)
        opts.minIOS = minIOS.trimmingCharacters(in: .whitespaces)
        opts.iconPNG = iconURL
        opts.entitlements = entitlements
        opts.removePlugins = removePlugins
        opts.removeWatch = removeWatch
        opts.removeURLSchemes = removeSchemes
        opts.fileSharing = fileSharing
        opts.container = inside
        opts.removeEmbedded = Array(dropEmbedded)
        do {
            let fromSources = state.installedTweaks.filter { picked.contains($0.identifier) }.map(state.tweakURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let all = fromSources + tweaks.filter { !fromSources.contains($0) } + replacements.values
            remote = onServer
            let report: @MainActor (Double, String) -> Void = { f, s in
                self.progress = f
                self.stage = s
            }
            let result: SignedApp
            if onServer {
                result = try await state.performRemoteSign(app: app, cert: c, options: opts, tweaks: all, progress: report)
            } else {
                result = try await state.performSign(app: app, cert: c, options: opts, tweaks: all, progress: report)
            }
            progress = 1
            done = result
            state.show(LF("%@ is signed", result.name))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.secondary)
        }
    }
}
