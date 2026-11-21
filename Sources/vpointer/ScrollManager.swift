import Foundation
import CoreGraphics

/// Manages the macOS Natural Scrolling (Swipe Scroll Direction) setting
/// with immediate WindowServer updates and global preference persistence.
final class ScrollManager {
    private typealias CGSMainConnectionIDFunc = @convention(c) () -> UInt32
    private typealias CGSSetSwipeScrollDirectionFunc = @convention(c) (UInt32, Bool) -> Int32

    private static let preferenceKey = "com.apple.swipescrolldirection" as CFString
    private static let notificationName = Notification.Name("SwipeScrollDirectionDidChangeNotification")

    private let mainConnectionID: CGSMainConnectionIDFunc?
    private let setSwipeScrollDirection: CGSSetSwipeScrollDirectionFunc?

    init() {
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        if let handle {
            if let sym = dlsym(handle, "CGSMainConnectionID") {
                mainConnectionID = unsafeBitCast(sym, to: CGSMainConnectionIDFunc.self)
            } else {
                mainConnectionID = nil
            }
            if let sym = dlsym(handle, "CGSSetSwipeScrollDirection") {
                setSwipeScrollDirection = unsafeBitCast(sym, to: CGSSetSwipeScrollDirectionFunc.self)
            } else {
                setSwipeScrollDirection = nil
            }
        } else {
            mainConnectionID = nil
            setSwipeScrollDirection = nil
        }
    }

    /// Reads the current Natural Scrolling state from global preferences.
    var isNaturalScrollingEnabled: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let value = CFPreferencesGetAppBooleanValue(Self.preferenceKey, kCFPreferencesAnyApplication, &valid)
        return valid.boolValue ? value : true
    }

    /// Sets Natural Scrolling immediately system-wide.
    /// - Parameter enabled: `true` to enable Natural Scrolling, `false` to disable it.
    @discardableResult
    func setNaturalScrolling(enabled: Bool) -> Bool {
        // 1. Apply immediately to the WindowServer via CoreGraphics (CGS)
        if let mainConnectionID, let setSwipeScrollDirection {
            let cid = mainConnectionID()
            _ = setSwipeScrollDirection(cid, enabled)
        }

        // 2. Persist in global user preferences (NSGlobalDomain)
        CFPreferencesSetValue(
            Self.preferenceKey,
            enabled as CFBoolean,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )

        // 3. Notify other processes (such as System Settings) about the change
        DistributedNotificationCenter.default().post(
            name: Self.notificationName,
            object: nil
        )

        return isNaturalScrollingEnabled == enabled
    }
}
