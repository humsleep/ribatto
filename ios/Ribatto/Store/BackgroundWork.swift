import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps a detection or render the user started running after they switch to
/// another app, and tells them when it is done.
///
/// iOS 26 lets an app keep user-started work alive in the background
/// (`BGContinuedProcessingTask`): the system shows the progress on the Lock
/// Screen and Dynamic Island, and the user can cancel it there. Detection only
/// needs the CPU and always qualifies. Encoding a clip needs the GPU, which a
/// background app is allowed only with the
/// `com.apple.developer.background-tasks.continued-processing.gpu` entitlement
/// and only on devices that support it — so the request asks for the GPU when
/// the device offers it and falls back to CPU-only when that is refused. Without
/// the GPU the render loop still pauses between clips (SessionStore
/// `waitForForeground`) and says so in a notification.
///
/// Before iOS 26 none of this exists: the app gets ~30 s and is suspended, so
/// only the notifications apply.
@MainActor
final class BackgroundWork {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Ribatto-Info.plist.
    private static let prefix = (Bundle.main.bundleIdentifier ?? "com.ribatto.app") + ".process"

    /// Called whenever `canRenderInBackground` may have changed.
    var onChange: (() -> Void)?

    /// Nested begin/end pairs: a multi-video import runs several sessions
    /// under ONE task, because a request can only be submitted while the app
    /// is in front — the second session would usually start in the background.
    private var depth = 0
    /// The running BGContinuedProcessingTask (typed loosely: iOS 17 target).
    private var task: AnyObject?
    private var gpuRequested = false
    /// The identifier of the current run's request. A handler from an earlier
    /// run that arrives late is completed on the spot instead of taking over.
    private var currentID: String?
    /// `finish` came before the system handed us the task.
    private var finishedEarly: Bool?
    private var lastFraction = 0.0
    private var lastTitle = ""
    private var lastSubtitle = ""

    /// True while a continued task with background GPU is alive — clips can
    /// be encoded with the app in the background.
    private(set) var canRenderInBackground = false {
        didSet { if oldValue != canRenderInBackground { onChange?() } }
    }
    /// True while any continued task is alive (detection keeps going).
    private(set) var keepsRunning = false

    // MARK: - Task

    func begin(title: String, subtitle: String) {
        depth += 1
        guard depth == 1 else { return }
        lastFraction = 0
        lastTitle = title
        lastSubtitle = subtitle
        finishedEarly = nil
        if #available(iOS 26.0, *) { submit(title: title, subtitle: subtitle) }
    }

    func update(fraction: Double, title: String, subtitle: String) {
        lastFraction = min(max(fraction, 0), 1)
        let retitled = title != lastTitle || subtitle != lastSubtitle
        lastTitle = title
        lastSubtitle = subtitle
        if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
            t.progress.completedUnitCount = Int64(lastFraction * 1000)
            if retitled { t.updateTitle(title, subtitle: subtitle) }
        }
    }

    func end(success: Bool) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
            t.progress.completedUnitCount = t.progress.totalUnitCount
            t.setTaskCompleted(success: success)
            detach()
        } else {
            finishedEarly = success
        }
    }

    @available(iOS 26.0, *)
    private func submit(title: String, subtitle: String) {
        let id = Self.prefix + "." + UUID().uuidString
        // Registered per submission: continued-processing handlers are exempt
        // from the "before launch finishes" rule, and a unique id per run keeps
        // a late handler from an old run off the new one.
        currentID = id
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) {
            [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                guard let self, self.currentID == id else {
                    task.setTaskCompleted(success: false); return
                }
                self.attach(task)
            }
        }
        guard registered else { return }      // identifier missing from Info.plist
        let gpuOptions = BGTaskScheduler.supportedResources.contains(.gpu) ? [true, false] : [false]
        #if DEBUG
        DebugLog.write("submit supportedResources=\(BGTaskScheduler.supportedResources.rawValue)")
        #endif
        for gpu in gpuOptions {
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: title,
                                                           subtitle: subtitle)
            // Run now or not at all: a queued request would start after the
            // work it was meant to cover has already paused.
            request.strategy = .fail
            if gpu { request.requiredResources = .gpu }
            do {
                try BGTaskScheduler.shared.submit(request)
                #if DEBUG
                DebugLog.write("submitted gpu=\(gpu)")
                #endif
                gpuRequested = gpu
                return
            } catch {
                // Without the entitlement a GPU request is rejected outright;
                // detection is still worth keeping alive.
                #if DEBUG
                DebugLog.write("submit gpu=\(gpu) failed: \(error)")
                #endif
            }
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ t: BGContinuedProcessingTask) {
        if let success = finishedEarly {
            t.setTaskCompleted(success: success)
            finishedEarly = nil
            return
        }
        guard depth > 0 else { t.setTaskCompleted(success: true); return }
        #if DEBUG
        DebugLog.write("attached gpu=\(gpuRequested) supported=\(BGTaskScheduler.supportedResources.rawValue)")
        #endif
        task = t
        keepsRunning = true
        canRenderInBackground = gpuRequested
        t.progress.totalUnitCount = 1000
        t.progress.completedUnitCount = Int64(lastFraction * 1000)
        t.updateTitle(lastTitle, subtitle: lastSubtitle)
        // The user cancelled it from the Lock Screen, or the system took the
        // time back. The work itself carries on as far as iOS allows and
        // pauses between clips, exactly as without the task.
        t.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.task, current === t else { return }
                    #if DEBUG
                    DebugLog.write("expired")
                    #endif
                    t.setTaskCompleted(success: false)
                    self.detach()
                }
            }
        }
    }

    /// The render is about to wait for the app to come back (no background
    /// GPU). Holding the task open meanwhile left a Lock Screen progress bar
    /// frozen for as long as the user stayed away, and the system expires a
    /// task that stops moving anyway. The paused notification takes over.
    func pause() {
        guard #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask else { return }
        t.setTaskCompleted(success: false)
        detach()
    }

    private func detach() {
        task = nil
        keepsRunning = false
        canRenderInBackground = false
    }

    // MARK: - Notifications

    /// Asked when the user first starts processing — the moment the reason for
    /// it is visible — not at launch.
    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Posts only when the user is not looking at the app; on screen the
    /// session card already says it.
    static func notify(id: String, title: String, body: String) {
        // Only when the app is really gone: `.inactive` is also Control Center
        // pulled down over a screen that already says it.
        guard UIApplication.shared.applicationState == .background else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A one-second trigger, not nil: posted with no trigger at the moment
        // the app left the screen, the request was accepted without error and
        // never shown (simulator, 2026-10-02).
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content,
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1,
                                                                             repeats: false)))
    }

    static func withdraw(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}

#if DEBUG
/// Device-test trace in Documents/debug.log — the USB console drops whenever
/// the phone locks, which is exactly when background behaviour matters.
enum DebugLog {
    static func write(_ line: String) {
        print("[background] " + line)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("debug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
