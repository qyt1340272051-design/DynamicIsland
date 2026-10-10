import Foundation
import OSLog

public nonisolated enum PluginLogLevel: String, Equatable, Sendable {
    case debug, info, warning, error
}

public nonisolated struct PluginLogEntry: Equatable, Sendable {
    public let pluginID: String
    public let level: PluginLogLevel
    public let message: String
    public let timestamp: Date
}

public nonisolated enum PluginBridgeErrorCode: String, Error, Equatable, Sendable {
    case invalidArguments, unsupportedVersion, unsupportedMethod, inactiveExecution
    case capabilityRequired, permissionRequired, quotaExceeded, rateLimited, activityNotFound, coreRejected

    fileprivate var message: String {
        switch self {
        case .invalidArguments: "Bridge arguments are invalid."
        case .unsupportedVersion: "Bridge API version is unsupported."
        case .unsupportedMethod: "Bridge method is unsupported."
        case .inactiveExecution: "Plugin execution is inactive."
        case .capabilityRequired: "The required capability is not declared."
        case .permissionRequired: "The required permission is not declared."
        case .quotaExceeded: "A Host resource limit was exceeded."
        case .rateLimited: "Activity updates exceed the Host rate limit."
        case .activityNotFound: "The plugin Activity was not found."
        case .coreRejected: "The Host rejected the operation."
        }
    }
}

/// The sole data-only JS-to-Core boundary. Requests arrive serially on
/// MainActor from one worker; replies never contain a JSValue or native object.
/// Storage survives Runtime replacement in this Host instance, in memory only.
@MainActor
public final class PluginJSBridge {
    public nonisolated static let apiVersion = "1.0.0"

    private struct StoredValue {
        let value: PluginBridgeJSON
        let bytes: Int
    }

    private enum Operation {
        case log(message: String, level: PluginLogLevel)
        case activity(PluginActivityConverter.Request)
        case end(id: String)
        case get(key: String)
        case set(key: String, value: PluginBridgeJSON, bytes: Int)
        case remove(key: String)
        case clear
        case unsupportedAction
    }

    private var logEntries: [String: [PluginLogEntry]] = [:]
    private var storage: [String: [String: StoredValue]] = [:]
    private var activityRateLimiter = PluginActivityRateLimiter()
    private let activityRateClock: @MainActor () -> TimeInterval
    private let logger = Logger(subsystem: "DynamicIsland", category: "PluginJSBridge")

    public init(activityRateClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.activityRateClock = activityRateClock
    }

    public func logs(for pluginID: String) -> [PluginLogEntry] { logEntries[pluginID] ?? [] }

    public nonisolated static func activityID(pluginID: String, localID: String) -> String {
        "plugin:\(pluginID):\(localID)"
    }

    /// Both wrapper validation and this independent Host validation are
    /// required. Plugin identity, source and declarations come from the Host.
    func handle(_ requestJSON: String, package: ValidatedPluginPackage,
                context: PluginExecutionContext) -> String {
        do {
            let operation = try parseRequest(requestJSON)
            guard context.id == package.manifest.id else { throw PluginBridgeErrorCode.coreRejected }
            var result = PluginBridgeJSON.null
            try context.perform {
                result = try execute(operation, manifest: package.manifest, context: context)
            }
            return response(.object(["ok": .boolean(true), "value": result]))
        } catch let error as PluginBridgeErrorCode {
            return failure(error)
        } catch let error as PluginBridgeJSON.ParseError {
            return failure(error == .limitExceeded ? .quotaExceeded : .invalidArguments)
        } catch let error as PluginExecutionError {
            return failure(error == .inactiveExecution ? .inactiveExecution : .coreRejected)
        } catch let error as ActivityManagerError {
            switch error {
            case .quotaExceeded: return failure(.quotaExceeded)
            case .notFound: return failure(.activityNotFound)
            case .disabledSource: return failure(.inactiveExecution)
            default: return failure(.coreRejected)
            }
        } catch {
            return failure(.coreRejected)
        }
    }

    private func execute(_ operation: Operation, manifest: PluginManifest,
                         context: PluginExecutionContext) throws -> PluginBridgeJSON {
        let pluginID = context.id
        switch operation {
        case .log(let message, let level):
            let entry = PluginLogEntry(pluginID: pluginID, level: level, message: message, timestamp: Date())
            var entries = logEntries[pluginID] ?? []
            if entries.count == 100 { entries.removeFirst() }
            entries.append(entry)
            logEntries[pluginID] = entries
            switch level {
            case .debug: logger.debug("plugin=\(pluginID, privacy: .private) \(message, privacy: .private)")
            case .info: logger.info("plugin=\(pluginID, privacy: .private) \(message, privacy: .private)")
            case .warning: logger.warning("plugin=\(pluginID, privacy: .private) \(message, privacy: .private)")
            case .error: logger.error("plugin=\(pluginID, privacy: .private) \(message, privacy: .private)")
            }
        case .activity(let request):
            try require(request.isUpdate ? .updateActivity : .publishActivity, manifest: manifest)
            if request.actions?.isEmpty == false { try require(.handleActions, manifest: manifest) }
            let id = Self.activityID(pluginID: pluginID, localID: request.localID)
            let existing = try context.activity(id: id)
            let activity = try request.materialize(source: context.source, namespacedID: id, now: Date(), existing: existing)
            let instant = activityRateClock()
            guard activityRateLimiter.canAdmit(pluginID: pluginID, at: instant) else {
                throw PluginBridgeErrorCode.rateLimited
            }
            if request.isUpdate { try context.updateActivity(activity) }
            else { try context.publish(activity, maximumActivities: 16) }
            activityRateLimiter.recordSuccess(pluginID: pluginID, at: instant)
            return .object(["id": .string(request.localID)])
        case .end(let id):
            try require(.endActivity, manifest: manifest)
            try context.endActivity(id: Self.activityID(pluginID: pluginID, localID: id))
        case .get(let key):
            try requireStorage(manifest)
            return storage[pluginID]?[key]?.value ?? .null
        case .set(let key, let value, let bytes):
            try requireStorage(manifest)
            var values = storage[pluginID] ?? [:]
            values[key] = StoredValue(value: value, bytes: bytes)
            let totalBytes = values.reduce(0) { $0 + $1.key.utf8.count + $1.value.bytes }
            guard values.count <= 128, totalBytes <= 65_536 else {
                throw PluginBridgeErrorCode.quotaExceeded
            }
            storage[pluginID] = values
        case .remove(let key):
            try requireStorage(manifest)
            storage[pluginID]?.removeValue(forKey: key)
            if storage[pluginID]?.isEmpty == true { storage.removeValue(forKey: pluginID) }
        case .clear:
            try requireStorage(manifest)
            storage.removeValue(forKey: pluginID)
        case .unsupportedAction:
            try require(.handleActions, manifest: manifest)
            // Callback registration and SwiftUI dispatch are the T26 contract.
            throw PluginBridgeErrorCode.unsupportedMethod
        }
        return .null
    }

    private func require(_ capability: PluginCapability, manifest: PluginManifest) throws {
        guard manifest.capabilities.contains(capability) else { throw PluginBridgeErrorCode.capabilityRequired }
    }

    private func requireStorage(_ manifest: PluginManifest) throws {
        try require(.localStorage, manifest: manifest)
        guard manifest.permissions.contains(.localStorage) else { throw PluginBridgeErrorCode.permissionRequired }
    }

    private func parseRequest(_ source: String) throws -> Operation {
        let envelope = try object(PluginBridgeJSON.parse(source), required: ["apiVersion", "method", "params"])
        let version = try string(envelope["apiVersion"], maximumBytes: 32, nonempty: true)
        guard version == Self.apiVersion else { throw PluginBridgeErrorCode.unsupportedVersion }
        let method = try string(envelope["method"], maximumBytes: 64, nonempty: true)
        guard let params = envelope["params"] else { throw PluginBridgeErrorCode.invalidArguments }
        switch method {
        case "log":
            let fields = try object(params, required: ["message", "level"])
            let message = try string(fields["message"], maximumBytes: 1_024)
            guard let level = PluginLogLevel(rawValue: try string(fields["level"], maximumBytes: 16)) else {
                throw PluginBridgeErrorCode.invalidArguments
            }
            return .log(message: message, level: level)
        case "activity.publish", "activity.update":
            return .activity(try PluginActivityConverter.parse(params, isUpdate: method == "activity.update"))
        case "activity.end":
            let fields = try object(params, required: ["id"])
            return .end(id: try identifier(fields["id"], maximumBytes: 80))
        case "storage.get", "storage.remove":
            let fields = try object(params, required: ["key"])
            let key = try storageKey(fields["key"])
            return method == "storage.get" ? .get(key: key) : .remove(key: key)
        case "storage.set":
            let fields = try object(params, required: ["key", "value"])
            let key = try storageKey(fields["key"])
            guard let value = fields["value"] else { throw PluginBridgeErrorCode.invalidArguments }
            try value.validate(maximumDepth: 8, maximumNodes: 256, maximumStringBytes: 4_096)
            let bytes = try value.encodedData().count
            guard bytes <= 8_192 else { throw PluginBridgeErrorCode.quotaExceeded }
            return .set(key: key, value: value, bytes: bytes)
        case "storage.clear":
            _ = try object(params, required: [])
            return .clear
        case "actions.on", "actions.off":
            let fields = try object(params, required: ["actionID"])
            _ = try identifier(fields["actionID"], maximumBytes: 80)
            return .unsupportedAction
        default:
            guard case .object = params else { throw PluginBridgeErrorCode.invalidArguments }
            throw PluginBridgeErrorCode.unsupportedMethod
        }
    }

    private func object(_ value: PluginBridgeJSON, required: Set<String>,
                        optional: Set<String> = []) throws -> [String: PluginBridgeJSON] {
        guard case .object(let fields) = value, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return fields
    }

    private func string(_ value: PluginBridgeJSON?, maximumBytes: Int,
                        nonempty: Bool = false) throws -> String {
        guard case .string(let string) = value,
              !nonempty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        guard string.utf8.count <= maximumBytes else { throw PluginBridgeErrorCode.quotaExceeded }
        return string
    }

    private func identifier(_ value: PluginBridgeJSON?, maximumBytes: Int,
                            allowsColon: Bool = false) throws -> String {
        let result = try string(value, maximumBytes: maximumBytes, nonempty: true)
        guard result.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || (allowsColon && byte == 58)
        }) else { throw PluginBridgeErrorCode.invalidArguments }
        return result
    }

    private func storageKey(_ value: PluginBridgeJSON?) throws -> String {
        let key = try string(value, maximumBytes: 128, nonempty: true)
        guard !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return key
    }

    private func failure(_ code: PluginBridgeErrorCode) -> String {
        response(.object(["ok": .boolean(false), "error": .object([
            "code": .string(code.rawValue), "message": .string(code.message)
        ])]))
    }

    private func response(_ value: PluginBridgeJSON) -> String {
        (try? value.encodedString()) ?? "{\"ok\":false,\"error\":{\"code\":\"coreRejected\",\"message\":\"The Host rejected the operation.\"}}"
    }
}
