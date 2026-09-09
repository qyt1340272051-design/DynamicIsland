import CoreAudio
import Foundation

public protocol VolumeObservation: AnyObject {
    nonisolated func cancel()
}

public protocol VolumeService {
    func currentVolume() throws -> Float
    func isMuted() throws -> Bool
    func setVolume(_ volume: Float) throws
    func setMuted(_ muted: Bool) throws
    func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation?
}

public extension VolumeService {
    func isMuted() throws -> Bool { false }

    func setMuted(_ muted: Bool) throws {
        if muted {
            try setVolume(0)
        }
    }

    func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation? {
        nil
    }
}

public enum VolumeServiceError: LocalizedError {
    case defaultOutputDeviceUnavailable
    case volumeUnsupported
    case coreAudioFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .defaultOutputDeviceUnavailable:
            return "无法获取默认输出设备"
        case .volumeUnsupported:
            return "当前输出设备不支持系统音量控制"
        case .coreAudioFailure(let status):
            return "Core Audio 操作失败：\(status)"
        }
    }
}

public nonisolated struct CoreAudioVolumeService: VolumeService {
    public init() {}

    public func currentVolume() throws -> Float {
        let device = try defaultOutputDevice()
        let addresses = volumeAddresses(for: device, requiresSettable: false)
        guard !addresses.isEmpty else {
            throw VolumeServiceError.volumeUnsupported
        }

        let levels = try addresses.map { try readFloatProperty(on: device, address: $0) }
        let average = levels.reduce(0, +) / Float32(levels.count)
        return min(max(average, 0), 1)
    }

    public func isMuted() throws -> Bool {
        let device = try defaultOutputDevice()
        let addresses = muteAddresses(for: device, requiresSettable: false)
        guard !addresses.isEmpty else {
            return try currentVolume() == 0
        }

        return try addresses.contains { address in
            try readUInt32Property(on: device, address: address) != 0
        }
    }

    public func setVolume(_ volume: Float) throws {
        let device = try defaultOutputDevice()
        let addresses = volumeAddresses(for: device, requiresSettable: true)
        guard !addresses.isEmpty else {
            throw VolumeServiceError.volumeUnsupported
        }

        let clamped = Float32(min(max(volume, 0), 1))
        for address in addresses {
            try setFloatProperty(clamped, on: device, address: address)
        }

        try setMuteIfSupported(clamped == 0, on: device)
    }

    public func setMuted(_ muted: Bool) throws {
        let device = try defaultOutputDevice()
        let addresses = muteAddresses(for: device, requiresSettable: true)

        if addresses.isEmpty {
            if muted {
                try setVolume(0)
                return
            }
            throw VolumeServiceError.volumeUnsupported
        }

        let value: UInt32 = muted ? 1 : 0
        for address in addresses {
            try setUInt32Property(value, on: device, address: address)
        }
    }

    public func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation? {
        let observation = CoreAudioVolumeObservation(service: self, handler: handler)
        try observation.start()
        return observation
    }

    fileprivate func defaultOutputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw VolumeServiceError.defaultOutputDeviceUnavailable
        }

        return deviceID
    }

    fileprivate func observedAddresses(for device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        allPropertyAddresses(selector: kAudioDevicePropertyVolumeScalar, device: device)
            + allPropertyAddresses(selector: kAudioDevicePropertyMute, device: device)
    }

    private func volumeAddresses(
        for device: AudioDeviceID,
        requiresSettable: Bool
    ) -> [AudioObjectPropertyAddress] {
        propertyAddresses(
            selector: kAudioDevicePropertyVolumeScalar,
            device: device,
            requiresSettable: requiresSettable
        )
    }

    private func muteAddresses(
        for device: AudioDeviceID,
        requiresSettable: Bool
    ) -> [AudioObjectPropertyAddress] {
        propertyAddresses(
            selector: kAudioDevicePropertyMute,
            device: device,
            requiresSettable: requiresSettable
        )
    }

    private func propertyAddresses(
        selector: AudioObjectPropertySelector,
        device: AudioDeviceID,
        requiresSettable: Bool
    ) -> [AudioObjectPropertyAddress] {
        let mainAddress = propertyAddress(selector: selector, element: kAudioObjectPropertyElementMain)
        if supportsProperty(mainAddress, on: device, requiresSettable: requiresSettable) {
            return [mainAddress]
        }

        return (1...max(channelCount(for: device), 1)).compactMap { channel in
            let address = propertyAddress(selector: selector, element: AudioObjectPropertyElement(channel))
            return supportsProperty(address, on: device, requiresSettable: requiresSettable) ? address : nil
        }
    }

    private func allPropertyAddresses(
        selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        let mainAddress = propertyAddress(selector: selector, element: kAudioObjectPropertyElementMain)
        let channelAddresses = (1...max(channelCount(for: device), 1)).map { channel in
            propertyAddress(selector: selector, element: AudioObjectPropertyElement(channel))
        }

        return ([mainAddress] + channelAddresses).filter { address in
            supportsProperty(address, on: device, requiresSettable: false)
        }
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func supportsProperty(
        _ propertyAddress: AudioObjectPropertyAddress,
        on device: AudioDeviceID,
        requiresSettable: Bool
    ) -> Bool {
        var address = propertyAddress
        guard AudioObjectHasProperty(device, &address) else {
            return false
        }
        guard requiresSettable else {
            return true
        }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func channelCount(for device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }

    private func readFloatProperty(
        on device: AudioDeviceID,
        address propertyAddress: AudioObjectPropertyAddress
    ) throws -> Float32 {
        var address = propertyAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw VolumeServiceError.coreAudioFailure(status)
        }
        return value
    }

    private func readUInt32Property(
        on device: AudioDeviceID,
        address propertyAddress: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var address = propertyAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw VolumeServiceError.coreAudioFailure(status)
        }
        return value
    }

    private func setFloatProperty(
        _ value: Float32,
        on device: AudioDeviceID,
        address propertyAddress: AudioObjectPropertyAddress
    ) throws {
        var address = propertyAddress
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutableValue)
        guard status == noErr else {
            throw VolumeServiceError.coreAudioFailure(status)
        }
    }

    private func setUInt32Property(
        _ value: UInt32,
        on device: AudioDeviceID,
        address propertyAddress: AudioObjectPropertyAddress
    ) throws {
        var address = propertyAddress
        var mutableValue = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutableValue)
        guard status == noErr else {
            throw VolumeServiceError.coreAudioFailure(status)
        }
    }

    private func setMuteIfSupported(_ muted: Bool, on device: AudioDeviceID) throws {
        let addresses = muteAddresses(for: device, requiresSettable: true)
        let value: UInt32 = muted ? 1 : 0
        for address in addresses {
            try setUInt32Property(value, on: device, address: address)
        }
    }
}

private nonisolated final class CoreAudioVolumeObservation: VolumeObservation {
    private let service: CoreAudioVolumeService
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.rong5.dynamic-island.volume-observation")
    private let queueKey = DispatchSpecificKey<Void>()
    private var observedDevice = AudioDeviceID(kAudioObjectUnknown)
    private var observedDeviceAddresses: [AudioObjectPropertyAddress] = []
    private var isObservingDefaultDevice = false
    private var isCancelled = false

    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, !self.isCancelled else { return }
        try? self.bindToDefaultOutputDevice()
        self.handler()
    }

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, !self.isCancelled else { return }
        self.handler()
    }

    init(service: CoreAudioVolumeService, handler: @escaping @Sendable () -> Void) {
        self.service = service
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        cancel()
    }

    func start() throws {
        try synchronized {
            var address = defaultOutputDeviceAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultDeviceListener
            )
            guard status == noErr else {
                throw VolumeServiceError.coreAudioFailure(status)
            }

            isObservingDefaultDevice = true
            try bindToDefaultOutputDevice()
        }
    }

    func cancel() {
        synchronized {
            guard !isCancelled else { return }
            isCancelled = true
            removeDeviceListeners()

            if isObservingDefaultDevice {
                var address = defaultOutputDeviceAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    defaultDeviceListener
                )
                isObservingDefaultDevice = false
            }
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }

    private var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func bindToDefaultOutputDevice() throws {
        removeDeviceListeners()

        let device = try service.defaultOutputDevice()
        observedDevice = device

        for propertyAddress in service.observedAddresses(for: device) {
            var address = propertyAddress
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceListener)
            if status == noErr {
                observedDeviceAddresses.append(propertyAddress)
            }
        }
    }

    private func removeDeviceListeners() {
        guard observedDevice != AudioDeviceID(kAudioObjectUnknown) else {
            return
        }

        for propertyAddress in observedDeviceAddresses {
            var address = propertyAddress
            AudioObjectRemovePropertyListenerBlock(observedDevice, &address, queue, deviceListener)
        }
        observedDeviceAddresses.removeAll()
        observedDevice = AudioDeviceID(kAudioObjectUnknown)
    }
}
