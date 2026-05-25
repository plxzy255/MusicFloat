import AppKit
import XCTest
@testable import MusicFloat

final class SystemLifecycleObserverTests: XCTestCase {
    @MainActor
    func testObserverRoutesWorkspaceSuspendAndResumeEvents() async {
        let center = NotificationCenter()
        var suspended: [SystemLifecycleObserver.Event] = []
        var resumed: [SystemLifecycleObserver.Event] = []
        let observer = SystemLifecycleObserver(
            notificationCenter: center,
            onSuspend: { event in
                suspended.append(event)
            },
            onResume: { event in
                resumed.append(event)
            }
        )

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(suspended, [.willSleep, .sessionDidResignActive])
        XCTAssertEqual(resumed, [.didWake, .sessionDidBecomeActive])

        observer.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(suspended, [.willSleep, .sessionDidResignActive])
    }
}
