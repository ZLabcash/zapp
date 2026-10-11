import BackgroundTasks
import UIKit

/// Syncing while ZApp isn't on screen, within what iOS allows:
///
/// - Leaving the app mid-sync: iOS grants about a minute more to keep scanning.
/// - Scheduled: iOS wakes the app now and then (a short refresh), and for longer when the
///   phone is charging with network, usually at night, to catch up on blocks. iOS decides
///   when, or whether, these run.
@MainActor
enum BackgroundSync {
    static let refreshID = "cash.zscan.zapp.refresh"
    static let catchUpID = "cash.zscan.zapp.sync"

    private static var extraTime = UIBackgroundTaskIdentifier.invalid

    /// Registers the handlers; must run during launch (the App's init).
    static func register(_ wallet: WalletModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            Task { @MainActor in
                schedule()
                run(task, wallet)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: catchUpID, using: nil) { task in
            Task { @MainActor in
                schedule()
                run(task, wallet)
            }
        }
    }

    /// Asks iOS for the next wake-ups (replacing earlier requests).
    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let catchUp = BGProcessingTaskRequest(identifier: catchUpID)
        catchUp.requiresExternalPower = true
        catchUp.requiresNetworkConnectivity = true
        catchUp.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(catchUp)
    }

    /// Syncs until the wallet is up to date or iOS takes the time back.
    private static func run(_ task: BGTask, _ wallet: WalletModel) {
        let work = Task { @MainActor in
            let done = await wallet.syncInBackground()
            task.setTaskCompleted(success: done)
        }
        // Out of time: stop waiting; the task above then reports it unfinished.
        task.expirationHandler = { work.cancel() }
    }

    /// The app went to the background: keep syncing for the extra time iOS grants.
    static func didEnterBackground(_ wallet: WalletModel) {
        schedule()
        guard !wallet.synced, extraTime == .invalid else { return }
        extraTime = UIApplication.shared.beginBackgroundTask(withName: "sync") { end() }
        Task { @MainActor in
            _ = await wallet.syncInBackground()
            end()
        }
    }

    /// Back on screen, or out of time.
    static func end() {
        guard extraTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(extraTime)
        extraTime = .invalid
    }
}
