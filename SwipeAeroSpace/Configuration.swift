import Combine
import Foundation
import TOMLKit
import os

/// A reloadable overlay. File values never replace the user's saved preferences.
/// The file is watched for changes and reloaded automatically.
final class Configuration: ObservableObject {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/swipeareospace/config.toml")
    static let shared = Configuration()

    let objectWillChange = ObservableObjectPublisher()
    private let url: URL
    // Gesture processing may read settings from a background queue during reload.
    private let lock = NSLock()
    private var state: Snapshot
    private var watcher: DispatchSourceFileSystemObject?
    private var fallbackWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var fileSignature: FileSignature

    private struct FileSignature: Equatable {
        var exists: Bool
        var inode: Int
        var modified: Date?
        var size: Int
    }

    private struct Snapshot {
        var values: [String: Any] = [:]
        var errorMessage: String?
        var fileExists: Bool = false
    }

    private var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var values: [String: Any] { snapshot.values }
    var errorMessage: String? { snapshot.errorMessage }
    var fileExists: Bool { snapshot.fileExists }

    init(url: URL = Configuration.fileURL) {
        self.url = url
        state = Self.load(url: url)
        fileSignature = Self.signature(of: url)
        armWatcher()
    }

    deinit {
        watcher?.cancel()
        fallbackWatcher?.cancel()
    }

    /// Auto-reload: watch the config file's directory (editors replace files
    /// atomically, which invalidates a vnode watch on the file itself). When
    /// the directory doesn't exist yet, watch its parent so that creating the
    /// directory (or the file) re-arms this watcher.
    private func armWatcher() {
        let directoryURL = url.deletingLastPathComponent()
        if watcher == nil {
            watcher = watchDirectory(directoryURL) { [weak self] in
                self?.handleDirectoryEvent()
            }
        }
        if watcher == nil && fallbackWatcher == nil {
            fallbackWatcher = watchDirectory(
                directoryURL.deletingLastPathComponent()
            ) { [weak self] in
                self?.armWatcher()
            }
        }
    }

    private func watchDirectory(
        _ directory: URL, handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func handleDirectoryEvent() {
        scheduleReload()
        let directoryURL = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            watcher?.cancel()
            watcher = nil
            armWatcher()
        }
    }

    /// Debounced so editor save churn (atomic replace plus metadata writes)
    /// collapses into a single reload.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadIfChanged()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadIfChanged() {
        let signature = Self.signature(of: url)
        guard signature != fileSignature else { return }
        fileSignature = signature
        reload()
    }

    private static func signature(of url: URL) -> FileSignature {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            )
        else {
            return FileSignature(exists: false, inode: 0, modified: nil, size: 0)
        }
        return FileSignature(
            exists: true,
            inode: (attributes[.systemFileNumber] as? Int) ?? 0,
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? Int) ?? 0
        )
    }

    /// Called by Settings on the main thread; publish the entire file at once.
    func reload() {
        let updated = Self.load(url: url)
        objectWillChange.send()
        lock.lock()
        state = updated
        lock.unlock()
    }

    /// Detect newly created/deleted files without implicitly reloading settings.
    func refreshFilePresence() {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists != fileExists else { return }
        objectWillChange.send()
        lock.lock()
        state.fileExists = exists
        lock.unlock()
    }

    private static func load(url: URL) -> Snapshot {
        var result = Snapshot()
        result.fileExists = FileManager.default.fileExists(atPath: url.path)
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            result.values = try parse(contents)
        } catch CocoaError.fileReadNoSuchFile {
            result.fileExists = false
        } catch {
            let message = "Could not load \(url.path): \(error). Using saved settings."
            result.errorMessage = message
            Logger(subsystem: "club.mediosz.SwipeAeroSpace", category: "Configuration")
                .error("\(message, privacy: .public)")
        }
        return result
    }

    static func parse(_ contents: String) throws -> [String: Any] {
        let table = try TOMLTable(string: contents)
        return try TOMLDecoder().decode(Overrides.self, from: table).values
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Overrides: Decodable {
        var values: [String: Any] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys {
                func invalid(_ message: String) -> DecodingError {
                    .dataCorruptedError(forKey: key, in: container, debugDescription: message)
                }
                switch key.stringValue {
                case "wrap", "natural", "skip-empty", "multiSwipe", "swipeUpOverview",
                     "show-empty-workspaces":
                    values[key.stringValue] = try container.decode(Bool.self, forKey: key)
                case "threshold":
                    let value: Double
                    if let integer = try? container.decode(Int.self, forKey: key) {
                        value = Double(integer)
                    } else {
                        value = try container.decode(Double.self, forKey: key)
                    }
                    guard value.isFinite && value > 0 else {
                        throw invalid("threshold must be a finite number greater than zero")
                    }
                    values[key.stringValue] = value
                case "maxSteps":
                    let value = try container.decode(Int.self, forKey: key)
                    guard (2...9).contains(value) else {
                        throw invalid("maxSteps must be an integer between 2 and 9")
                    }
                    values[key.stringValue] = value
                case "fingers", "swipeUpFingers":
                    let value = try container.decode(String.self, forKey: key)
                    guard ["Three", "Four"].contains(value) else {
                        throw invalid("\(key.stringValue) must be \"Three\" or \"Four\"")
                    }
                    values[key.stringValue] = value
                default:
                    throw invalid("Unknown setting: \(key.stringValue)")
                }
            }
        }
    }
}
