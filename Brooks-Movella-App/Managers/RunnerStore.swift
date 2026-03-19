import Foundation
import Combine

final class RunnerStore: ObservableObject {
    static let shared = RunnerStore()

    @Published var runners: [Runner] = []
    @Published var isMultiRunnerMode: Bool {
        didSet { UserDefaults.standard.set(isMultiRunnerMode, forKey: "multi_runner_mode") }
    }

    private let lock = NSLock()
    private var _runnersSnapshot: [Runner] = []

    private let fileURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("runners.json")
    }()

    private init() {
        isMultiRunnerMode = UserDefaults.standard.bool(forKey: "multi_runner_mode")
        load()
    }

    // MARK: - Thread-Safe Reads

    /// Thread-safe lookup by runner ID. Safe to call from any queue.
    func runner(forId id: String) -> Runner? {
        lock.lock()
        defer { lock.unlock() }
        return _runnersSnapshot.first { $0.id == id }
    }

    /// Thread-safe lookup by sensor UUID. Safe to call from any queue.
    func runner(forSensorUuid uuid: String) -> Runner? {
        lock.lock()
        defer { lock.unlock() }
        return _runnersSnapshot.first { $0.sensorUuids.contains(uuid) }
    }

    private func syncSnapshot() {
        lock.lock()
        _runnersSnapshot = runners
        lock.unlock()
    }

    // MARK: - CRUD

    @discardableResult
    func addRunner(label: String) -> Runner {
        let runner = Runner(label: label)
        runners.append(runner)
        syncSnapshot()
        save()
        return runner
    }

    /// Insert or replace a runner with a specific ID.
    func setRunner(_ runner: Runner) {
        if let idx = runners.firstIndex(where: { $0.id == runner.id }) {
            runners[idx] = runner
        } else {
            runners.append(runner)
        }
        syncSnapshot()
        save()
    }

    func removeRunner(id: String) {
        runners.removeAll { $0.id == id }
        syncSnapshot()
        save()
    }

    func assignSensor(uuid: String, to runnerId: String) {
        // Enforce uniqueness — remove from any other runner first
        for i in runners.indices {
            runners[i].sensorUuids.removeAll { $0 == uuid }
        }
        if let idx = runners.firstIndex(where: { $0.id == runnerId }) {
            runners[idx].sensorUuids.append(uuid)
        }
        syncSnapshot()
        save()
    }

    func unassignSensor(uuid: String, from runnerId: String) {
        if let idx = runners.firstIndex(where: { $0.id == runnerId }) {
            runners[idx].sensorUuids.removeAll { $0 == uuid }
        }
        syncSnapshot()
        save()
    }

    func updateLabel(runnerId: String, label: String) {
        if let idx = runners.firstIndex(where: { $0.id == runnerId }) {
            runners[idx].label = label
        }
        syncSnapshot()
        save()
    }

    func clearAll() {
        runners.removeAll()
        syncSnapshot()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Runner].self, from: data) else { return }
        runners = decoded
        syncSnapshot()
    }

    func save() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(runners) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
