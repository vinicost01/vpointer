import Foundation
import IOKit.hid

/// Monitors external mouse (USB and Bluetooth) connect/disconnect events in real time
/// using IOHIDManager, ignoring the MacBook's built-in Trackpad and external trackpads.
final class MouseMonitor {
    typealias ChangeHandler = ([String]) -> Void

    private var manager: IOHIDManager?
    private var connectedMice: [IOHIDDevice: String] = [:]
    private let onChange: ChangeHandler

    private static let internalTransports: Set<String> = [
        "FIFO", "SPI", "SPU", "I2C"
    ]

    init(onChange: @escaping ChangeHandler) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    var connectedMouseNames: [String] {
        connectedMice.values.sorted()
    }

    var hasExternalMouse: Bool {
        !connectedMice.isEmpty
    }

    func start() {
        guard manager == nil else { return }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { ctx, _, _, device in
            guard let ctx else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDeviceAdded(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { ctx, _, _, device in
            guard let ctx else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        manager = hidManager
        refreshConnectedDevices()
    }

    func stop() {
        guard let hidManager = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        connectedMice.removeAll()
    }

    /// Rescans all currently connected devices (useful after waking from sleep).
    func refreshConnectedDevices() {
        guard let hidManager = manager else { return }
        var updated: [IOHIDDevice: String] = [:]

        if let deviceSet = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> {
            for device in deviceSet where Self.isExternalMouse(device) {
                updated[device] = Self.deviceName(device)
            }
        }

        connectedMice = updated
        notifyChange()
    }

    private func handleDeviceAdded(_ device: IOHIDDevice) {
        guard Self.isExternalMouse(device) else { return }
        connectedMice[device] = Self.deviceName(device)
        notifyChange()
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard connectedMice.removeValue(forKey: device) != nil else { return }
        notifyChange()
    }

    private func notifyChange() {
        let names = connectedMouseNames
        DispatchQueue.main.async { [weak self] in
            self?.onChange(names)
        }
    }

    private static func isExternalMouse(_ device: IOHIDDevice) -> Bool {
        // Ignore built-in devices (MacBook internal Trackpad)
        if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool, builtIn {
            return false
        }
        if let builtInNum = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber, builtInNum.boolValue {
            return false
        }

        // Ignore internal MacBook buses
        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
           internalTransports.contains(transport.uppercased()) {
            return false
        }

        // Ignore trackpads (including external Magic Trackpad or combo devices)
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
        if product.contains("trackpad") {
            return false
        }

        // Ignore devices without a known physical transport (e.g., internal virtual devices)
        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
           transport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        return true
    }

    private static func deviceName(_ device: IOHIDDevice) -> String {
        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
           !product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return product
        }
        if let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String,
           !manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(manufacturer) Mouse"
        }
        return "Mouse Externo"
    }
}
