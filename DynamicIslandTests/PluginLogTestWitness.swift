import Foundation
@testable import DynamicIsland

/// Test markers remain in the plugin VM. They are recorded only after the Host
/// acknowledges the log Promise; production diagnostics never retain them.
nonisolated enum PluginLogTestWitness {
    static func source(_ original: String) -> String {
        let instrumented = original.replacingOccurrences(of: "island.log(", with: "__testIslandLog(")
        return """
        const __testLogWitness = [];
        const __testIslandLog = (() => {
            const apply = Reflect.apply, then = Promise.prototype.then, push = Array.prototype.push;
            const slice = Array.prototype.slice, log = island.log;
            return function() {
                const args = apply(slice, arguments, []);
                return apply(then, apply(log, undefined, args), [value => {
                    apply(push, __testLogWitness, [args[0]]); return value;
                }]);
            };
        })();
        \(instrumented)
        """
    }

    static func instrumentTemporaryEntry(at root: URL) throws {
        let entry = root.appendingPathComponent("index.js")
        try source(String(contentsOf: entry, encoding: .utf8)).write(to: entry, atomically: true, encoding: .utf8)
    }

    static func countExpression(pluginID: String, message: String) -> String {
        "island.plugin.id === \(literal(pluginID)) && typeof __testLogWitness !== 'undefined' ? " +
            "__testLogWitness.filter(value => value === \(literal(message))).length : 0"
    }

    @MainActor
    static func count(_ runtime: PluginRuntime, pluginID: String, message: String) async throws -> Int {
        let value = try await runtime.evaluateForTesting(countExpression(pluginID: pluginID, message: message))
        guard case .number(let number) = value else { return 0 }
        return Int(number)
    }

    @MainActor
    static func hasMarker(_ runtimes: [PluginRuntime], pluginID: String, message: String, count: Int = 1) async -> Bool {
        for runtime in runtimes where runtime.snapshot.state == .running {
            if let found = try? await self.count(runtime, pluginID: pluginID, message: message), found >= count { return true }
        }
        return false
    }

    private static func literal(_ text: String) -> String {
        let bytes = try! JSONEncoder().encode(text)
        return String(decoding: bytes, as: UTF8.self)
    }
}
