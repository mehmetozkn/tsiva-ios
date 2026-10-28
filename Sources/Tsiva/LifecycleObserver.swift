import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Flushes queued events when the app moves to the background, so they are not lost if the app is killed.
/// Does nothing on platforms without UIKit.
final class LifecycleObserver {
    private var token: NSObjectProtocol?

    init(client: @escaping @Sendable () -> TsivaClient?) {
        #if canImport(UIKit) && !os(watchOS)
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let client = client() else { return }
                BackgroundFlush.start(client)
            }
        }
        #endif
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Asks the system for extra background time while the final upload runs.
@MainActor
private final class BackgroundFlush {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    static func start(_ client: TsivaClient) {
        let flush = BackgroundFlush()
        // `UIApplication.shared` is unavailable in app extensions, so it is looked up dynamically.
        let application = UIApplication.value(forKey: "sharedApplication") as? UIApplication
        flush.taskID = application?.beginBackgroundTask(withName: "TsivaFlush") {
            flush.end(application)
        } ?? .invalid

        Task { @MainActor in
            await client.flush()
            flush.end(application)
        }
    }

    private func end(_ application: UIApplication?) {
        guard taskID != .invalid else { return }
        application?.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
#endif
