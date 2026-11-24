import BackgroundTasks
import UIKit

/// Wakes SayoSign for finished background downloads and refreshes sources (and so tweaks) in the background.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        // Reconnects to downloads that went on while SayoSign was closed.
        _ = Downloader.shared.session
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloader.identifier else { completionHandler(); return }
        Downloader.shared.backgroundCompletion = completionHandler
        _ = Downloader.shared.session
    }
}

enum BackgroundRefresh {
    static let identifier = "dev.murk.sayosign.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    /// Asks iOS for a run in about an hour (it picks the moment; Background App Refresh must be on).
    @MainActor static func schedule() {
        let s = AppState.shared
        guard s.settings.autoUpdateTweaks, !s.installedTweaks.isEmpty, !s.sources.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let r = BGAppRefreshTaskRequest(identifier: identifier)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let done = Once()
        let work = Task { @MainActor in
            schedule()
            // Downloads it starts go on in the background session after this task ends.
            await AppState.shared.refreshSources()
            if done.first() { task.setTaskCompleted(success: true) }
        }
        task.expirationHandler = {
            work.cancel()
            if done.first() { task.setTaskCompleted(success: false) }
        }
    }

    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }
}
