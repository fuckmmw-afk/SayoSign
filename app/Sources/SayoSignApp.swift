import SwiftUI
import UniformTypeIdentifiers

struct SayoSignApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var certImport = CertificateImportCoordinator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(certImport)
                .tint(Theme.rose)
                .preferredColorScheme(state.settings.appearance == 1 ? .light : state.settings.appearance == 2 ? .dark : nil)
                .onOpenURL { state.handleOpen($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var certImport: CertificateImportCoordinator
    @Environment(\.scenePhase) var phase

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $state.tab) {
                LibraryView()
                    .tabItem { Label(L("Library"), systemImage: "square.stack.3d.up.fill") }
                    .tag(0)
                CertificatesView()
                    .tabItem { Label(L("Certificates"), systemImage: "checkmark.seal.fill") }
                    .tag(1)
                SourcesView()
                    .tabItem { Label(L("Sources"), systemImage: "globe") }
                    .tag(2)
                SettingsView()
                    .tabItem { Label(L("Settings"), systemImage: "gearshape.fill") }
                    .tag(3)
            }
            if let t = state.toast {
                ToastView(text: t)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .onTapGesture { state.toast = nil }
                    .zIndex(10)
            }
            if let b = state.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(b).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassy()
                .padding(.top, 8)
                .zIndex(9)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.toast)
        .sheet(isPresented: $certImport.presented) {
            ImportCertificateView(prefillP12: certImport.p12, prefillProfile: certImport.profile)
                .environmentObject(state)
        }
        .sheet(item: $state.pendingSign) { app in
            SignView(app: app).environmentObject(state)
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await state.scanInbox(); await state.autoRefreshTweaks() } }
        }
        .task {
            if Diagnostics.enabled { await Diagnostics.run(state) }
            await state.scanInbox()
            await state.autoRefreshTweaks()
            if state.certificates.contains(where: { $0.ocspChecked == nil || $0.ocspChecked! < Date().addingTimeInterval(-3600) }) {
                await state.refreshAllOCSP()
            }
        }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
    static let tipa = UTType(filenameExtension: "tipa") ?? .data
    static let p12 = UTType(filenameExtension: "p12") ?? .data
    static let mobileprovision = UTType(filenameExtension: "mobileprovision") ?? .data
    static let deb = UTType(filenameExtension: "deb") ?? .data
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
}
