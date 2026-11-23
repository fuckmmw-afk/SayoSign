import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var state: AppState
    @State private var adding = false
    @State private var newURL = ""
    @State private var search = ""
    @State private var filter: UUID?
    /// 0 = apps, 1 = tweaks.
    @State private var mode = 0

    var hasTweaks: Bool { state.sources.contains { !($0.tweaks ?? []).isEmpty } }

    var allTweaks: [RepoTweak] {
        let t = state.sources.filter { filter == nil || $0.id == filter }.flatMap { $0.tweaks ?? [] }
        if search.isEmpty { return t }
        return t.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search)
            || $0.developer.localizedCaseInsensitiveContains(search) || $0.targets.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var allApps: [RepoApp] {
        let apps = state.sources.filter { filter == nil || $0.id == filter }.flatMap { $0.apps }
        if search.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) || $0.developer.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(nil, title: L("All"))
                            ForEach(state.sources) { s in chip(s.id, title: s.name) }
                        }
                        .padding(.vertical, 4)
                    }
                    if hasTweaks {
                        Picker("", selection: $mode) {
                            Text(L("Apps")).tag(0)
                            Text(L("Tweaks")).tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    if state.sources.isEmpty {
                        EmptyState(title: L("No sources"), subtitle: L("Add an AltStore, SideStore, Feather or ESign repository URL to browse apps."))
                    } else if (mode == 0 || !hasTweaks) ? allApps.isEmpty : allTweaks.isEmpty {
                        EmptyState(title: L("Nothing found"), subtitle: L("Try another search or refresh your sources."))
                    }
                    if mode == 1 && hasTweaks {
                        LazyVStack(spacing: 10) {
                            ForEach(allTweaks) { t in RepoTweakRow(tweak: t) }
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(allApps) { app in
                                NavigationLink(destination: RepoAppDetail(app: app)) {
                                    RepoAppRow(app: app)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("Sources"))
            .searchable(text: $search, prompt: L("Search apps"))
            .refreshable { await state.refreshSources() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus.circle.fill").font(.title2).symbolRenderingMode(.hierarchical) }
                }
            }
            .alert(L("Add source"), isPresented: $adding) {
                TextField("https://example.com/repo.json", text: $newURL)
                Button(L("Cancel"), role: .cancel) { newURL = "" }
                Button(L("Add")) {
                    let u = newURL
                    newURL = ""
                    Task { await state.addSource(u) }
                }
            } message: {
                Text(L("Paste a repository link"))
            }
        }
        .navigationViewStyle(.stack)
    }

    func chip(_ id: UUID?, title: String) -> some View {
        let on = filter == id
        return Button { filter = id } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
                .foregroundColor(on ? .white : .primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let id = id, let s = state.sources.first(where: { $0.id == id }) {
                Button { UIPasteboard.general.string = s.url } label: { Label(L("Copy link"), systemImage: "doc.on.doc") }
                Button(role: .destructive) { state.removeSource(s); filter = nil } label: { Label(L("Remove"), systemImage: "trash") }
            }
        }
    }
}

struct RepoAppRow: View {
    @EnvironmentObject var state: AppState
    let app: RepoApp
    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppIconView(image: nil, url: app.iconURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text(app.subtitle.isEmpty ? app.developer : app.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if !app.version.isEmpty { Pill(text: "v" + app.version) }
                        if app.size > 0 { Pill(text: formatSize(app.size), color: .secondary) }
                    }
                }
                Spacer(minLength: 6)
                Button(L("Get")) {
                    Task { await state.get(app) }
                    state.show(LF("Downloading %@", app.name))
                }
                .buttonStyle(SmallButtonStyle())
            }
        }
    }
}

struct RepoAppDetail: View {
    @EnvironmentObject var state: AppState
    let app: RepoApp
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    AppIconView(image: nil, url: app.iconURL, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.title2.weight(.bold))
                        Text(app.developer).foregroundColor(.secondary)
                        Button(L("Get")) {
                            Task { await state.get(app) }
                            state.tab = 0
                        }
                        .buttonStyle(SmallButtonStyle())
                    }
                }
                HStack(spacing: 8) {
                    if !app.version.isEmpty { Pill(text: "v" + app.version) }
                    if app.size > 0 { Pill(text: formatSize(app.size), color: .secondary) }
                    if !app.bundleID.isEmpty { Pill(text: app.bundleID, color: .secondary) }
                }
                if !app.screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.screenshots, id: \.self) { s in
                                AsyncImage(url: URL(string: s)) { p in
                                    if let i = p.image { i.resizable().scaledToFit() } else { Color(.secondarySystemFill) }
                                }
                                .frame(height: 380)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
                let tweaks = (state.sources.first { $0.id == app.sourceID }?.tweaks ?? []).filter { !app.bundleID.isEmpty && $0.fits(app.bundleID) }
                if !tweaks.isEmpty {
                    Text(L("Tweaks for this app")).font(.headline)
                    ForEach(tweaks) { t in RepoTweakRow(tweak: t) }
                }
                if !app.description.isEmpty {
                    Text(app.description).font(.body)
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RepoTweakRow: View {
    @EnvironmentObject var state: AppState
    let tweak: RepoTweak
    @State private var working = false

    var body: some View {
        let inst = state.installed(tweak)
        let outdated = inst.map { $0.version != tweak.version || $0.downloadURL != tweak.downloadURL } ?? false
        Card {
            HStack(spacing: 12) {
                if tweak.iconURL.isEmpty {
                    Image(systemName: tweak.downloadURL.lowercased().hasSuffix(".deb") ? "shippingbox.fill" : "puzzlepiece.extension.fill")
                        .font(.title2).foregroundColor(.white)
                        .frame(width: 54, height: 54)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.gradient))
                } else {
                    AppIconView(image: nil, url: tweak.iconURL)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(tweak.name).font(.headline).lineLimit(1)
                    Text(targetsText).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if !tweak.version.isEmpty { Pill(text: "v" + tweak.version) }
                        if tweak.size > 0 { Pill(text: formatSize(tweak.size), color: .secondary) }
                        if let i = inst, outdated, !i.version.isEmpty { Pill(text: LF("Have %@", i.version), color: .secondary) }
                    }
                }
                Spacer(minLength: 6)
                if working {
                    ProgressView()
                } else {
                    Button(inst == nil ? L("Get") : (outdated ? L("Update") : L("Installed"))) {
                        working = true
                        Task {
                            await state.installTweak(tweak)
                            working = false
                        }
                    }
                    .buttonStyle(SmallButtonStyle(filled: inst == nil || outdated))
                }
            }
            if !tweak.description.isEmpty {
                Text(tweak.description).font(.caption).foregroundColor(.secondary).lineLimit(3).padding(.top, 6)
            }
        }
        .contextMenu {
            if let i = inst {
                Button { state.setAutoUpdate(i, !i.autoUpdate) } label: {
                    Label(i.autoUpdate ? L("Stop updating automatically") : L("Update automatically"),
                          systemImage: i.autoUpdate ? "pause.circle" : "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { state.removeTweak(i) } label: { Label(L("Remove"), systemImage: "trash") }
            }
            Button { UIPasteboard.general.string = tweak.downloadURL } label: { Label(L("Copy link"), systemImage: "doc.on.doc") }
        }
    }

    var targetsText: String {
        if tweak.targets.isEmpty || tweak.targets.contains("*") { return tweak.developer.isEmpty ? L("Any app") : tweak.developer }
        let names = tweak.targets.map { id in state.sources.flatMap { $0.apps }.first { $0.bundleID == id }?.name ?? id }
        return LF("For %@", names.joined(separator: ", "))
    }
}
