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
    case storageReadFailed, storageWriteFailed
    case permissionNotGranted, permissionDenied, permissionRevoked, stalePermissionReview

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
        case .storageReadFailed: "Plugin storage could not be read."
        case .storageWriteFailed: "Plugin storage could not be written."
        case .permissionNotGranted: "The Host has not granted the requested permission."
        case .permissionDenied: "The Host denied the requested permission."
        case .permissionRevoked: "The Host revoked the permission or its previous authorization."
        case .stalePermissionReview: "The permission review does not belong to the current plugin package."
        }
    }
}

/// The sole data-only JS-to-Core boundary. Requests arrive serially on
/// MainActor from one worker; replies never contain a JSValue or native object.
/// Storage I/O is delegated to its own actor; no JavaScript reference or
/// plugin-selected path reaches the filesystem.
@MainActor
public final class PluginJSBridge {
    public nonisolated static let apiVersion = "1.0.0"

    private enum Operation {
        case log(message: String, level: PluginLogLevel)
        case activity(PluginActivityConverter.Request)
        case end(id: String)
        case get(key: String)
        case set(key: String, value: PluginBridgeJSON)
        case remove(key: String)
        case clear
        case readClipboard
        case writeClipboard(text: String)
        case registerAction(actionID: String, registrationID: String)
        case unregisterAction(actionID: String)
    }

    private var logEntries: [String: [PluginLogEntry]] = [:]
    private let storage: PluginStorage
    private let permissions: PermissionManager
    private let network: PluginNetworkBroker
    private let files: PluginFileBroker
    private let clipboard: PluginClipboardBroker
    private var activityRateLimiter = PluginActivityRateLimiter()
    private let activityRateClock: @MainActor () -> TimeInterval
    private let logger = Logger(subsystem: "DynamicIsland", category: "PluginJSBridge")

    public init(storage: PluginStorage = PluginStorage(),
                permissions: PermissionManager? = nil,
                network: PluginNetworkBroker? = nil,
                files: PluginFileBroker? = nil,
                clipboard: PluginClipboardBroker? = nil,
                activityRateClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.storage = storage
        self.permissions = permissions ?? PermissionManager()
        self.network = network ?? PluginNetworkBroker()
        self.files = files ?? PluginFileBroker()
        self.clipboard = clipboard ?? PluginClipboardBroker()
        self.activityRateClock = activityRateClock
    }

    public func logs(for pluginID: String) -> [PluginLogEntry] { logEntries[pluginID] ?? [] }

    public nonisolated static func activityID(pluginID: String, localID: String) -> String {
        "plugin:\(pluginID):\(localID)"
    }

    /// Both wrapper validation and this independent Host validation are
    /// required. Plugin identity, source and declarations come from the Host.
    func handle(_ requestJSON: String, package: ValidatedPluginPackage,
                context: PluginExecutionContext, actionSession: PluginActionSession? = nil) async -> String {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                await dispatch(requestJSON, package: package, context: context, actionSession: actionSession) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    /// FIFO admission is separate from network and file-selection completion.
    /// User interaction cannot retain the queue used by actions and storage.
    func dispatch(_ requestJSON: String, package: ValidatedPluginPackage,
                  context: PluginExecutionContext, actionSession: PluginActionSession? = nil,
                  reply: @escaping @Sendable (String) -> Void) async {
        do {
            let envelope = try object(PluginBridgeJSON.parse(requestJSON), required: ["apiVersion", "method", "params"])
            if envelope["method"] == .string("files.chooseText") {
                try dispatchFile(envelope, package: package, context: context, reply: reply)
                return
            }
            if envelope["method"] != .string("network.fetch") {
                reply(await handleImmediate(requestJSON, package: package, context: context, actionSession: actionSession))
                return
            }
            guard envelope["apiVersion"] == .string(Self.apiVersion) else { throw PluginBridgeErrorCode.unsupportedVersion }
            guard context.id == package.manifest.id else { throw PluginBridgeErrorCode.coreRejected }
            try context.perform {}
            let request = try PluginNetworkRequest.parse(envelope["params"]!)
            let authorization = try permissions.require(permission: .network, package: package)
            let admission = context.networkAdmission
            try network.start(request: request, pluginID: context.id, authorization: authorization, admission: admission) { result in
                Task { @MainActor in
                    let response: String
                    do {
                        try context.perform {}
                        try admission.perform {
                            try authorization.perform(pluginID: context.id, permission: .network) {}
                        }
                        switch result {
                        case .success(let value):
                            response = self.response(.object(["ok": .boolean(true), "value": .object([
                                "status": .number(Double(value.status)), "body": .string(value.body),
                                "headers": .object(value.headers.mapValues { .string($0) })
                            ])]))
                        case .failure(let error): response = self.networkFailure(error)
                        }
                    } catch let error as PluginPermissionError {
                        response = self.failure(PluginBridgeErrorCode(rawValue: error.code) ?? .coreRejected)
                    } catch {
                        response = self.failure(.inactiveExecution)
                    }
                    reply(response)
                }
            }
        } catch let error as PluginBridgeErrorCode { reply(failure(error)) }
        catch let error as PluginBridgeJSON.ParseError { reply(failure(error == .limitExceeded ? .quotaExceeded : .invalidArguments)) }
        catch let error as PluginPermissionError { reply(failure(PluginBridgeErrorCode(rawValue: error.code) ?? .coreRejected)) }
        catch let error as PluginNetworkError { reply(networkFailure(error)) }
        catch let error as PluginFileError { reply(brokerFailure(code: error.code, message: error.errorDescription)) }
        catch let error as PluginResourceError { reply(failure(error == .inactiveExecution ? .inactiveExecution : .coreRejected)) }
        catch { reply(failure(.inactiveExecution)) }
    }

    private func dispatchFile(_ envelope: [String: PluginBridgeJSON], package: ValidatedPluginPackage,
                              context: PluginExecutionContext,
                              reply: @escaping @Sendable (String) -> Void) throws {
        guard envelope["apiVersion"] == .string(Self.apiVersion) else { throw PluginBridgeErrorCode.unsupportedVersion }
        guard context.id == package.manifest.id else { throw PluginBridgeErrorCode.coreRejected }
        try context.perform {}
        let request = try PluginFileRequest.parse(envelope["params"]!)
        let authorization = try permissions.require(permission: .userSelectedFiles, package: package)
        let admission = context.resourceAdmission
        try files.start(request: request, pluginID: context.id, displayName: package.manifest.name,
                        authorization: authorization, admission: admission) { result in
            Task { @MainActor in
                let response: String
                do {
                    try context.perform {}
                    try admission.perform {
                        try authorization.perform(pluginID: context.id, permission: .userSelectedFiles) {}
                    }
                    switch result {
                    case .success(let value):
                        let data = value.map { value in PluginBridgeJSON.object([
                            "name": .string(value.name), "type": .string(value.type),
                            "text": .string(value.text), "size": .number(Double(value.size))
                        ]) } ?? .null
                        response = self.response(.object(["ok": .boolean(true), "value": data]))
                    case .failure(let error):
                        response = self.brokerFailure(code: error.code, message: error.errorDescription)
                    }
                } catch let error as PluginPermissionError {
                    response = self.failure(PluginBridgeErrorCode(rawValue: error.code) ?? .coreRejected)
                } catch { response = self.failure(.inactiveExecution) }
                reply(response)
            }
        }
    }

    private func networkFailure(_ error: PluginNetworkError) -> String {
        brokerFailure(code: error.code, message: error.errorDescription)
    }

    private func brokerFailure(code: String, message: String?) -> String {
        response(.object(["ok": .boolean(false), "error": .object([
            "code": .string(code), "message": .string(message ?? "The Host rejected the operation.")
        ])]))
    }

    private func handleImmediate(_ requestJSON: String, package: ValidatedPluginPackage,
                                 context: PluginExecutionContext, actionSession: PluginActionSession?) async -> String {
        do {
            let operation = try parseRequest(requestJSON)
            guard context.id == package.manifest.id else { throw PluginBridgeErrorCode.coreRejected }
            var result = PluginBridgeJSON.null
            switch operation {
            case .get, .set, .remove, .clear:
                try context.perform { try requireStorage(package.manifest) }
                let authorization = try permissions.require(permission: .localStorage, package: package)
                result = try await executeStorage(operation, context: context, authorization: authorization)
                // The actor may have suspended this Host task while lifecycle
                // revoked the session. Late replies cannot revive that session.
                try context.perform { try authorization.perform {} }
            case .readClipboard, .writeClipboard:
                try context.perform {
                    try context.resourceAdmission.perform {
                        switch operation {
                        case .readClipboard:
                            let authorization = try permissions.require(permission: .readClipboard, package: package)
                            result = try clipboard.readText(pluginID: context.id, authorization: authorization).map { .string($0) } ?? .null
                        case .writeClipboard(let text):
                            let authorization = try permissions.require(permission: .writeClipboard, package: package)
                            try clipboard.writeText(text, pluginID: context.id, authorization: authorization)
                        default: break
                        }
                    }
                }
            default:
                try context.perform {
                    result = try execute(operation, manifest: package.manifest, context: context, actionSession: actionSession)
                }
            }
            return response(.object(["ok": .boolean(true), "value": result]))
        } catch let error as PluginBridgeErrorCode {
            return failure(error)
        } catch let error as PluginBridgeJSON.ParseError {
            return failure(error == .limitExceeded ? .quotaExceeded : .invalidArguments)
        } catch let error as PluginExecutionError {
            return failure(error == .inactiveExecution ? .inactiveExecution : .coreRejected)
        } catch let error as PluginStorageError {
            switch error {
            case .invalidArguments: return failure(.invalidArguments)
            case .quotaExceeded: return failure(.quotaExceeded)
            case .inactiveExecution: return failure(.inactiveExecution)
            case .readFailed: return failure(.storageReadFailed)
            case .writeFailed: return failure(.storageWriteFailed)
            }
        } catch let error as PluginPermissionError {
            return failure(PluginBridgeErrorCode(rawValue: error.code) ?? .coreRejected)
        } catch let error as PluginClipboardError {
            return brokerFailure(code: error.code, message: error.errorDescription)
        } catch let error as PluginResourceError {
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

    private func executeStorage(_ operation: Operation, context: PluginExecutionContext,
                                authorization: PluginPermissionLease) async throws -> PluginBridgeJSON {
        let admission = context.storageAdmission
        switch operation {
        case .get(let key):
            return try await storage.get(pluginID: context.id, key: key, admission: admission, authorization: authorization)
        case .set(let key, let value):
            try await storage.set(pluginID: context.id, key: key, value: value, admission: admission, authorization: authorization)
        case .remove(let key):
            try await storage.remove(pluginID: context.id, key: key, admission: admission, authorization: authorization)
        case .clear:
            try await storage.clear(pluginID: context.id, admission: admission, authorization: authorization)
        default:
            throw PluginBridgeErrorCode.coreRejected
        }
        return .null
    }

    private func execute(_ operation: Operation, manifest: PluginManifest,
                         context: PluginExecutionContext, actionSession: PluginActionSession?) throws -> PluginBridgeJSON {
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
            if PluginActivityConverter.hasLayouts(in: activity.presentation) {
                try require(.islandNodeUI, manifest: manifest)
            }
            if !PluginActivityConverter.layoutActionIDs(in: activity.presentation).isEmpty {
                try require(.handleActions, manifest: manifest)
            }
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
        case .get, .set, .remove, .clear, .readClipboard, .writeClipboard:
            // Brokers are handled by their independently gated paths above.
            throw PluginBridgeErrorCode.coreRejected
        case .registerAction(let actionID, let registrationID):
            try require(.handleActions, manifest: manifest)
            guard let actionSession, actionSession.matches(context: context) else {
                throw PluginBridgeErrorCode.inactiveExecution
            }
            try actionSession.register(actionID: actionID, registrationID: registrationID)
        case .unregisterAction(let actionID):
            try require(.handleActions, manifest: manifest)
            guard let actionSession, actionSession.matches(context: context) else {
                throw PluginBridgeErrorCode.inactiveExecution
            }
            try actionSession.unregister(actionID: actionID)
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
            return .set(key: key, value: value)
        case "storage.clear":
            _ = try object(params, required: [])
            return .clear
        case "clipboard.readText":
            _ = try object(params, required: [])
            return .readClipboard
        case "clipboard.writeText":
            let fields = try object(params, required: ["text"])
            return .writeClipboard(text: try string(fields["text"], maximumBytes: 4_096))
        case "actions.on":
            let fields = try object(params, required: ["actionID", "registrationID"])
            return .registerAction(actionID: try identifier(fields["actionID"], maximumBytes: 80),
                                   registrationID: try identifier(fields["registrationID"], maximumBytes: 80))
        case "actions.off":
            let fields = try object(params, required: ["actionID"])
            return .unregisterAction(actionID: try identifier(fields["actionID"], maximumBytes: 80))
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
