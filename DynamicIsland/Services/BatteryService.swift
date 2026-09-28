import AppKit
import Foundation
import IOKit.ps

public nonisolated enum BatteryPowerSource: String, Equatable, Sendable {
    case ac
    case battery
}

public nonisolated struct BatteryState: Equatable, Sendable {
    public let level: Double
    public let powerSource: BatteryPowerSource
    public let isCharging: Bool
    public let isCharged: Bool

    public init(
        level: Double,
        powerSource: BatteryPowerSource,
        isCharging: Bool,
        isCharged: Bool
    ) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.isCharged = isCharged
    }
}

public protocol BatteryObservation: AnyObject {
    nonisolated func cancel()
}

public protocol BatteryService {
    /// Returns `nil` on Macs without an internal battery.
    func currentState() throws -> BatteryState?
    func observeChanges(_ handler: @escaping @Sendable () -> Void) throws -> BatteryObservation?
}

public extension BatteryService {
    func observeChanges(_ handler: @escaping @Sendable () -> Void) throws -> BatteryObservation? {
        nil
    }
}

public enum BatteryServiceError: LocalizedError {
    case snapshotUnavailable
    case observationUnavailable

    public var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "无法读取电池状态"
        case .observationUnavailable:
            return "无法监听电池状态变化"
        }
    }
}

/// Reads IOKit only at startup and in response to power-source notifications.
/// No timer or polling loop is created.
public nonisolated struct IOKitBatteryService: BatteryService {
    public init() {}

    public func currentState() throws -> BatteryState? {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            throw BatteryServiceError.snapshotUnavailable
        }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedList = IOPSCopyPowerSourcesList(info) else {
            throw BatteryServiceError.snapshotUnavailable
        }
        let sources = unmanagedList.takeRetainedValue() as [AnyObject]

        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source) else {
                continue
            }
            let description = unmanagedDescription.takeUnretainedValue() as NSDictionary
            if let state = Self.parseInternalBattery(description) {
                return state
            }
        }
        return nil
    }

    public func observeChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws -> BatteryObservation? {
        let observation = IOKitBatteryObservation(handler: handler)
        try observation.start()
        return observation
    }

    static func parseInternalBattery(_ description: NSDictionary) -> BatteryState? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
              let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
              maximum.doubleValue > 0 else {
            return nil
        }
        let powerSource: BatteryPowerSource
        switch description[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue:
            powerSource = .ac
        case kIOPSBatteryPowerValue:
            powerSource = .battery
        default:
            return nil
        }
        let charging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
        let charged = (description[kIOPSIsChargedKey] as? NSNumber)?.boolValue ?? false
        return BatteryState(
            level: current.doubleValue / maximum.doubleValue,
            powerSource: powerSource,
            isCharging: charging,
            isCharged: charged
        )
    }
}

private nonisolated final class IOKitBatteryCallbackBox: @unchecked Sendable {
    let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

private nonisolated final class IOKitBatteryObservation: BatteryObservation, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackBox: IOKitBatteryCallbackBox
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var wakeObserver: NSObjectProtocol?

    init(handler: @escaping @Sendable () -> Void) {
        callbackBox = IOKitBatteryCallbackBox(handler: handler)
    }

    deinit {
        cancel()
    }

    func start() throws {
        let context = Unmanaged.passUnretained(callbackBox).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let box = Unmanaged<IOKitBatteryCallbackBox>
                .fromOpaque(rawContext)
                .takeUnretainedValue()
            box.handler()
        }, context) else {
            throw BatteryServiceError.observationUnavailable
        }
        let createdSource = unmanagedSource.takeRetainedValue()
        let mainRunLoop = CFRunLoopGetMain()
        lock.lock()
        source = createdSource
        runLoop = mainRunLoop
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [callbackBox] _ in
            callbackBox.handler()
        }
        lock.unlock()
        CFRunLoopAddSource(mainRunLoop, createdSource, .commonModes)
    }

    nonisolated func cancel() {
        let values: (CFRunLoopSource?, CFRunLoop?, NSObjectProtocol?)
        lock.lock()
        values = (source, runLoop, wakeObserver)
        source = nil
        runLoop = nil
        wakeObserver = nil
        lock.unlock()

        if let wakeObserver = values.2 {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        guard let source = values.0 else { return }
        CFRunLoopSourceInvalidate(source)
        if let runLoop = values.1 {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }
}
