import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - MultitouchSupport Private Framework Structs

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerId: Int32
    var handId: Int32
    var normalizedVector: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private typealias MTDeviceCreateListFunc = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTUnregisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTDeviceStartFunc = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFunc = @convention(c) (MTDeviceRef) -> Void

// MARK: - Global C Callback Trampoline

private weak var activeMiddleClickManager: MiddleClickManager?

private let multitouchCallback: MTContactCallback = { _, rawTouches, numFingers, timestamp, _ in
    let touches = rawTouches?.assumingMemoryBound(to: MTTouch.self)
    activeMiddleClickManager?.handleMultitouchFrame(
        touches: touches,
        numFingers: Int(numFingers),
        timestamp: timestamp
    )
    return 0
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<MiddleClickManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEventTap(type: type, event: event)
}

// MARK: - MiddleClickManager

/// Implements 3-finger Middle Click on Trackpad and Magic Mouse,
/// supporting both physical click (3-finger click) and light tap (3-finger tap).
final class MiddleClickManager {
    var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    var isClickEnabled: Bool = true
    var isTapEnabled: Bool = true
    var onAccessibilityStatusChanged: ((Bool) -> Void)?

    private(set) var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    // MultitouchSupport.framework symbols
    private let mtDeviceCreateList: MTDeviceCreateListFunc?
    private let mtRegisterCallback: MTRegisterContactFrameCallbackFunc?
    private let mtUnregisterCallback: MTUnregisterContactFrameCallbackFunc?
    private let mtDeviceStart: MTDeviceStartFunc?
    private let mtDeviceStop: MTDeviceStopFunc?

    private var mtDevices: [MTDeviceRef] = []
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var permissionCheckTimer: Timer?

    // Lock-protected state (accessed from MultitouchSupport thread and CGEventTap)
    private let stateLock = NSLock()
    private var currentFingerCount: Int = 0
    private var isSimulatingMiddleClick: Bool = false

    // State for 3-finger tap detection
    private var tapCandidate: Bool = false
    private var tapStartTimestamp: Double = 0
    private var tapStartX: Float = 0
    private var tapStartY: Float = 0
    private var gestureSawMoreThanThreeFingers: Bool = false

    private static let maxTapDuration: Double = 0.35
    private static let maxTapMovement: Float = 0.055

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        )
        if let handle {
            mtDeviceCreateList = dlsym(handle, "MTDeviceCreateList").map {
                unsafeBitCast($0, to: MTDeviceCreateListFunc.self)
            }
            mtRegisterCallback = dlsym(handle, "MTRegisterContactFrameCallback").map {
                unsafeBitCast($0, to: MTRegisterContactFrameCallbackFunc.self)
            }
            mtUnregisterCallback = dlsym(handle, "MTUnregisterContactFrameCallback").map {
                unsafeBitCast($0, to: MTUnregisterContactFrameCallbackFunc.self)
            }
            mtDeviceStart = dlsym(handle, "MTDeviceStart").map {
                unsafeBitCast($0, to: MTDeviceStartFunc.self)
            }
            mtDeviceStop = dlsym(handle, "MTDeviceStop").map {
                unsafeBitCast($0, to: MTDeviceStopFunc.self)
            }
        } else {
            mtDeviceCreateList = nil
            mtRegisterCallback = nil
            mtUnregisterCallback = nil
            mtDeviceStart = nil
            mtDeviceStop = nil
        }
    }

    deinit {
        stop()
    }

    /// Prompts the user for Accessibility permission via the macOS system dialog.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        updateAccessibilityStatus(trusted)
        if !trusted && isEnabled {
            startPermissionPolling()
        }
    }

    /// Restarts multitouch devices (useful after waking from sleep or connecting a Magic Trackpad).
    func restartDevicesIfRunning() {
        guard isEnabled, hasAccessibilityPermission else { return }
        stopMultitouch()
        startMultitouch()
    }

    private func start() {
        let trusted = AXIsProcessTrusted()
        updateAccessibilityStatus(trusted)

        guard trusted else {
            startPermissionPolling()
            return
        }

        stopPermissionPolling()
        startMultitouch()
        startEventTap()
    }

    private func stop() {
        stopPermissionPolling()
        stopEventTap()
        stopMultitouch()

        stateLock.lock()
        currentFingerCount = 0
        isSimulatingMiddleClick = false
        tapCandidate = false
        gestureSawMoreThanThreeFingers = false
        stateLock.unlock()
    }

    private func updateAccessibilityStatus(_ trusted: Bool) {
        let changed = (hasAccessibilityPermission != trusted)
        hasAccessibilityPermission = trusted
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.onAccessibilityStatusChanged?(trusted)
            }
        }
    }

    private func startPermissionPolling() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted {
                self.updateAccessibilityStatus(true)
                self.stopPermissionPolling()
                if self.isEnabled {
                    self.startMultitouch()
                    self.startEventTap()
                }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    // MARK: - MultitouchSupport Lifecycle

    private func startMultitouch() {
        guard mtDevices.isEmpty else { return }
        guard let createList = mtDeviceCreateList,
              let registerCallback = mtRegisterCallback,
              let startDevice = mtDeviceStart,
              let cfArray = createList()?.takeRetainedValue() else {
            return
        }

        activeMiddleClickManager = self

        let count = CFArrayGetCount(cfArray)
        for index in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: rawPtr)
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            registerCallback(device, multitouchCallback)
            startDevice(device, 0)
            mtDevices.append(device)
        }
    }

    private func stopMultitouch() {
        guard !mtDevices.isEmpty else { return }
        for device in mtDevices {
            mtUnregisterCallback?(device, multitouchCallback)
            mtDeviceStop?(device)
            Unmanaged<AnyObject>.fromOpaque(device).release()
        }
        mtDevices.removeAll()
        if activeMiddleClickManager === self {
            activeMiddleClickManager = nil
        }
    }

    // MARK: - CGEventTap Lifecycle

    private func startEventTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - Multitouch Frame Handling

    fileprivate func handleMultitouchFrame(
        touches: UnsafeMutablePointer<MTTouch>?,
        numFingers: Int,
        timestamp: Double
    ) {
        var shouldFireTapMiddleClick = false

        stateLock.lock()
        currentFingerCount = numFingers

        if isTapEnabled {
            if numFingers == 0 {
                if tapCandidate,
                   !isSimulatingMiddleClick,
                   !gestureSawMoreThanThreeFingers,
                   (timestamp - tapStartTimestamp) <= Self.maxTapDuration {
                    shouldFireTapMiddleClick = true
                }
                tapCandidate = false
                gestureSawMoreThanThreeFingers = false
            } else if numFingers > 3 {
                tapCandidate = false
                gestureSawMoreThanThreeFingers = true
            } else if numFingers == 3, let touches {
                var sumX: Float = 0
                var sumY: Float = 0
                for i in 0..<3 {
                    sumX += touches[i].normalizedVector.position.x
                    sumY += touches[i].normalizedVector.position.y
                }
                let avgX = sumX / 3.0
                let avgY = sumY / 3.0

                if !tapCandidate && !gestureSawMoreThanThreeFingers && !isSimulatingMiddleClick {
                    tapCandidate = true
                    tapStartTimestamp = timestamp
                    tapStartX = avgX
                    tapStartY = avgY
                } else if tapCandidate {
                    let dx = abs(avgX - tapStartX)
                    let dy = abs(avgY - tapStartY)
                    if dx > Self.maxTapMovement || dy > Self.maxTapMovement {
                        tapCandidate = false
                    }
                }
            }
        } else {
            tapCandidate = false
        }

        stateLock.unlock()

        if shouldFireTapMiddleClick {
            DispatchQueue.main.async {
                Self.postSyntheticMiddleClick()
            }
        }
    }

    // MARK: - Event Tap Handling (3-Finger Physical Click)

    fileprivate func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled, isClickEnabled else {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let fingers = currentFingerCount
        let simulating = isSimulatingMiddleClick

        switch type {
        case .leftMouseDown:
            if fingers == 3 {
                isSimulatingMiddleClick = true
                tapCandidate = false
                stateLock.unlock()

                Self.postMiddleMouseEvent(type: .otherMouseDown, from: event)
                return nil
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            if simulating {
                stateLock.unlock()
                Self.postMiddleMouseEvent(type: .otherMouseDragged, from: event)
                return nil
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if simulating {
                isSimulatingMiddleClick = false
                stateLock.unlock()
                Self.postMiddleMouseEvent(type: .otherMouseUp, from: event)
                return nil
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)

        default:
            stateLock.unlock()
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Synthetic Middle Click Posting

    private static func postMiddleMouseEvent(type: CGEventType, from sourceEvent: CGEvent) {
        let location = sourceEvent.location
        guard let middleEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else {
            return
        }
        middleEvent.flags = sourceEvent.flags
        middleEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        middleEvent.post(tap: .cghidEventTap)
    }

    private static func postSyntheticMiddleClick() {
        guard let currentLocation = CGEvent(source: nil)?.location else { return }

        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: currentLocation,
            mouseButton: .center
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: currentLocation,
            mouseButton: .center
        ) else {
            return
        }

        down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 2)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
