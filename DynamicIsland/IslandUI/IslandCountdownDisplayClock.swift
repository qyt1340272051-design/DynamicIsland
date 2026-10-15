import Combine
import Foundation

/// A single Host display pulse shared by mounted, visible, running nodes.
/// It never calls JavaScript or settles a countdown business record.
@MainActor
public final class IslandCountdownDisplayClock: ObservableObject {
    static let shared = IslandCountdownDisplayClock()
    @Published private(set) var revision: UInt64 = 0
    private var consumers: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var isShutdown = false

    var consumerCount: Int { consumers.count }
    var timerCount: Int { task == nil ? 0 : 1 }

    func setNeedsTicks(_ needed: Bool, for consumer: UUID) {
        guard !isShutdown else { return }
        if needed { consumers.insert(consumer) }
        else { consumers.remove(consumer) }
        guard !consumers.isEmpty else {
            generation = nil
            task?.cancel()
            task = nil
            return
        }
        guard task == nil else { return }
        let token = UUID()
        generation = token
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1), clock: .continuous) }
                catch { return }
                guard let self, self.generation == token, !self.consumers.isEmpty,
                      !Task.isCancelled else { return }
                self.revision &+= 1
            }
        }
    }

    /// An event-driven business change refreshes leaves without creating a timer.
    func invalidate() {
        guard !isShutdown else { return }
        revision &+= 1
    }

    func shutdown() {
        isShutdown = true
        generation = nil
        consumers.removeAll()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
