import Darwin
import Foundation

@MainActor
@Observable
final class SnippetsStore {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var snippets: [StoredSnippet] = []
    private(set) var state: State = .idle
    private(set) var issues: [SnippetRepository.Issue] = []
    private(set) var operationError: String?

    private(set) var snippetsDirectory: URL
    var onSnapshot: ((SnippetRepository.Snapshot) -> Void)?

    private var repository: SnippetRepository
    private let usageFileURL: URL
    @ObservationIgnored private var usage = SnippetUsage()
    @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var watcherRetryTask: Task<Void, Never>?
    private var generation = 0
    private var watcherGeneration = 0
    private var isStarted = false

    init(repository: SnippetRepository = SnippetRepository(), usageFileURL: URL? = nil) {
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
        self.usageFileURL =
            usageFileURL
            ?? repository.channelDirectory.appendingPathComponent("snippet-usage.json")
    }

    isolated deinit {
        reloadTask?.cancel()
        watcherRetryTask?.cancel()
        directoryWatcher?.cancel()
        for source in fileWatchers.values { source.cancel() }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reload(showLoadingState: true)
    }

    func stop() {
        isStarted = false
        generation &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        stopWatchers()
    }

    /// Moves to another folder; a running store stops, swaps, and loads the new one.
    func relocate(to repository: SnippetRepository) async {
        guard repository.snippetsDirectory != snippetsDirectory else { return }
        let wasStarted = isStarted
        stop()
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
        // Emptied first, so a folder that fails to load leaves no old snippet expanding.
        if !snippets.isEmpty || !issues.isEmpty {
            snippets = []
            issues = []
            onSnapshot?(SnippetRepository.Snapshot(records: [], issues: []))
        }
        guard wasStarted else { return }
        await start()
    }

    func retry() {
        guard isStarted else { return }
        scheduleReload(after: .zero, showLoadingState: true)
    }

    @discardableResult
    func create(_ snippet: Snippet) async throws -> StoredSnippet {
        let record = try await performMutation { try $0.create(snippet) }
        guard isStarted else { return record }
        var records = snippets.filter { $0.id != record.id }
        records.append(record)
        publishLocal(records: records)
        scheduleReload(after: .zero)
        return record
    }

    @discardableResult
    func importSnippets(_ imported: [Snippet]) async throws -> [StoredSnippet] {
        guard !imported.isEmpty else { return [] }
        let created = try await performMutation { try $0.create(imported) }
        guard isStarted else { return created }
        let createdIDs = Set(created.map(\.id))
        publishLocal(records: snippets.filter { !createdIDs.contains($0.id) } + created)
        scheduleReload(after: .zero)
        return created
    }

    @discardableResult
    func save(_ record: StoredSnippet) async throws -> StoredSnippet {
        let saved = try await performMutation {
            try $0.save(
                record.snippet,
                fileURL: record.fileURL,
                expectedRevision: record.sourceRevision)
        }
        guard isStarted else { return saved }
        var records = snippets.filter { $0.id != saved.id }
        records.append(saved)
        publishLocal(records: records)
        scheduleReload(after: .zero)
        return saved
    }

    func delete(id: StoredSnippet.ID) async throws {
        guard let record = record(id: id) else {
            throw SnippetRepository.RepositoryError.fileNotFound(URL(fileURLWithPath: id))
        }
        try await performMutation {
            try $0.delete(
                fileURL: record.fileURL,
                expectedRevision: record.sourceRevision)
        }
        guard isStarted else { return }
        publishLocal(records: snippets.filter { $0.id != id })
        scheduleReload(after: .zero)
    }

    func record(id: StoredSnippet.ID) -> StoredSnippet? {
        snippets.first(where: { $0.id == id })
    }

    private enum RepositoryResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(SnippetRepository.RepositoryError)
    }

    private func performMutation<Value: Sendable>(
        _ operation: @escaping @Sendable (SnippetRepository) throws -> Value
    ) async throws -> Value {
        reloadTask?.cancel()
        reloadTask = nil
        generation &+= 1
        let repository = repository

        let result = await Task.detached(priority: .utility) {
            do {
                return RepositoryResult.success(try operation(repository))
            } catch let error as SnippetRepository.RepositoryError {
                return RepositoryResult.failure(error)
            } catch {
                return RepositoryResult.failure(
                    .io(
                        fileURL: repository.snippetsDirectory,
                        message: error.localizedDescription))
            }
        }.value

        switch result {
        case .success(let value):
            operationError = nil
            return value
        case .failure(let error):
            operationError = error.localizedDescription
            throw error
        }
    }

    private func reload(showLoadingState: Bool) async {
        guard isStarted else { return }
        generation &+= 1
        let loadGeneration = generation
        if showLoadingState { state = .loading }
        let repository = repository

        let usageFileURL = usageFileURL
        usage.merge(
            await Task.detached(priority: .utility) {
                SnippetUsage.load(from: usageFileURL)
            }.value)

        let result = await Task.detached(priority: .utility) {
            do {
                return RepositoryResult.success(try repository.load())
            } catch let error as SnippetRepository.RepositoryError {
                return RepositoryResult.failure(error)
            } catch {
                return RepositoryResult.failure(
                    .io(
                        fileURL: repository.snippetsDirectory,
                        message: error.localizedDescription))
            }
        }.value

        guard isStarted, loadGeneration == generation else { return }
        switch result {
        case .success(let snapshot):
            apply(snapshot)
        case .failure(let error):
            state = .failed(error.localizedDescription)
            scheduleWatcherRetry()
        }
    }

    private func publishLocal(records: [StoredSnippet]) {
        apply(SnippetRepository.Snapshot(records: records, issues: issues))
    }

    /// The one place a snippet's order is decided: recency first, then name so it stays stable.
    private func apply(_ snapshot: SnippetRepository.Snapshot) {
        guard isStarted else { return }
        let records = snapshot.records.sorted(by: recordOrder)
        let isUnchanged =
            state == .ready
            && snippets == records
            && issues == snapshot.issues
        if !isUnchanged {
            snippets = records
            issues = snapshot.issues
            state = .ready
            onSnapshot?(SnippetRepository.Snapshot(records: records, issues: snapshot.issues))
        }
        if syncWatchers(with: snapshot) {
            scheduleReload(after: .milliseconds(150))
        }
    }

    private func scheduleReload(after delay: Duration, showLoadingState: Bool = false) {
        guard isStarted else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, self.isStarted, !Task.isCancelled else { return }
            await self.reload(showLoadingState: showLoadingState)
        }
    }

    private func syncWatchers(with snapshot: SnippetRepository.Snapshot) -> Bool {
        guard isStarted else { return false }
        watcherRetryTask?.cancel()
        watcherRetryTask = nil

        var changed = false
        if directoryWatcher == nil {
            changed = armDirectoryWatcher() || changed
        }

        let desiredPaths = Set(
            snapshot.records.map { $0.fileURL.standardizedFileURL.path }
                + snapshot.issues.map { $0.fileURL.standardizedFileURL.path })
        for path in Array(fileWatchers.keys) where !desiredPaths.contains(path) {
            fileWatchers.removeValue(forKey: path)?.cancel()
            changed = true
        }
        for path in desiredPaths where fileWatchers[path] == nil {
            changed = armFileWatcher(path: path) || changed
        }

        // Retry while anything is unwatched; a failed file watcher blinds us like a missing one.
        if directoryWatcher == nil || desiredPaths.contains(where: { fileWatchers[$0] == nil }) {
            scheduleWatcherRetry()
        }
        return changed
    }

    @discardableResult
    private func armDirectoryWatcher() -> Bool {
        let descriptor = Darwin.open(snippetsDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        watcherGeneration &+= 1
        let installedGeneration = watcherGeneration
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleDirectoryEvent(generation: installedGeneration)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        directoryWatcher = source
        source.resume()
        return true
    }

    @discardableResult
    private func armFileWatcher(path: String) -> Bool {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let installedGeneration = watcherGeneration
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleFileEvent(path: path, generation: installedGeneration)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        fileWatchers[path] = source
        source.resume()
        return true
    }

    private func handleDirectoryEvent(generation installedGeneration: Int) {
        guard isStarted, installedGeneration == watcherGeneration,
            let events = directoryWatcher?.data
        else { return }

        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            stopWatchers()
        }
        noteFilesystemChange()
    }

    private func handleFileEvent(path: String, generation installedGeneration: Int) {
        guard isStarted, installedGeneration == watcherGeneration,
            let source = fileWatchers[path]
        else { return }

        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            fileWatchers.removeValue(forKey: path)?.cancel()
        }
        noteFilesystemChange()
    }

    private func noteFilesystemChange() {
        generation &+= 1
        scheduleReload(after: .milliseconds(150))
    }

    private func stopWatchers() {
        watcherGeneration &+= 1
        directoryWatcher?.cancel()
        directoryWatcher = nil
        for source in fileWatchers.values { source.cancel() }
        fileWatchers.removeAll()
    }

    private func scheduleWatcherRetry() {
        guard isStarted, watcherRetryTask == nil else { return }
        watcherRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.isStarted, !Task.isCancelled else { return }
            self.watcherRetryTask = nil
            await self.reload(showLoadingState: false)
        }
    }

    /// A use counts once the text has landed, so a cancelled expansion never reorders anything.
    func recordUse(id: StoredSnippet.ID, at date: Date) {
        guard snippets.contains(where: { $0.id == id }) else { return }
        usage.record(path: id, at: date)
        let recorded = usage
        let usageFileURL = usageFileURL
        Task.detached(priority: .utility) { try? recorded.write(to: usageFileURL) }
        // Sorted in place: publishing a snapshot here would rebuild the palette mid-delivery.
        snippets.sort(by: recordOrder)
    }

    private func recordOrder(_ lhs: StoredSnippet, _ rhs: StoredSnippet) -> Bool {
        let left = recency(of: lhs)
        let right = recency(of: rhs)
        if left != right { return left > right }
        let comparison = lhs.snippet.name.localizedCaseInsensitiveCompare(rhs.snippet.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Saving and using both count; whichever happened last is the snippet's place in the list.
    private func recency(of record: StoredSnippet) -> Date {
        max(record.modifiedAt, usage.lastUsed(at: record.id) ?? .distantPast)
    }
}
