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
                case "toggleOverviewShortcut", "nextWorkspaceShortcut", "prevWorkspaceShortcut":
                    let raw = try container.decode(String.self, forKey: key)
                    do {
                        values[key.stringValue] = try ShortcutSpec.parse(raw)
                    } catch {
                        throw invalid("\(key.stringValue) is not a valid shortcut: \(error.localizedDescription)")
                    }
                default:
                    throw invalid("Unknown setting: \(key.stringValue)")
                }
            }
        }
    }
}

/// A validated keyboard shortcut parsed from config.toml. Kept free of AppKit
/// and the KeyboardShortcuts package so the configuration layer stays testable
/// in the SwiftPM harness; SwipeManager maps it onto a real shortcut.
struct ShortcutSpec: Equatable {
    let key: String
    let modifiers: Set<String>

    private static let modifierAliases: [String: String] = [
        "cmd": "cmd", "command": "cmd",
        "option": "option", "opt": "option", "alt": "option",
        "control": "control", "ctrl": "control",
        "shift": "shift",
        "fn": "fn", "function": "fn",
    ]

    private static let keyAliases: [String: String] = [
        "enter": "return",
        "esc": "escape",
        "backspace": "delete",
        "deleteforward": "forwarddelete", "forward-delete": "forwarddelete",
        "forward_delete": "forwarddelete",
        "page-up": "pageup", "page_up": "pageup",
        "page-down": "pagedown", "page_down": "pagedown",
        "uparrow": "up", "up-arrow": "up", "up_arrow": "up",
        "downarrow": "down", "down-arrow": "down", "down_arrow": "down",
        "leftarrow": "left", "left-arrow": "left", "left_arrow": "left",
        "rightarrow": "right", "right-arrow": "right", "right_arrow": "right",
        "↑": "up", "↓": "down", "←": "left", "→": "right",
        "↩": "return", "⏎": "return", "⎋": "escape", "⇥": "tab",
        "⌫": "delete", "⌦": "forwarddelete",
        "⇞": "pageup", "⇟": "pagedown", "↖": "home", "↘": "end",
    ]

    private static let validKeys: Set<String> = {
        var keys: Set<String> = [
            "space", "tab", "return", "escape", "delete", "forwarddelete",
            "home", "end", "pageup", "pagedown", "up", "down", "left", "right",
        ]
        for number in 1...20 {
            keys.insert("f\(number)")
        }
        for character in "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`" {
            keys.insert(String(character))
        }
        return keys
    }()

    static func parse(_ raw: String) throws -> ShortcutSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutParseError.empty
        }

        // Expand modifier symbols into delimited tokens so a single split works.
        var expanded = trimmed
        for (symbol, name) in [("⌘", "cmd"), ("⌥", "option"), ("⌃", "control"), ("⇧", "shift")] {
            expanded = expanded.replacingOccurrences(of: symbol, with: "+\(name)+")
        }

        let tokens = expanded
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty else {
            throw ShortcutParseError.empty
        }

        var modifiers = Set<String>()
        for token in tokens.dropLast() {
            guard let canonical = modifierAliases[token] else {
                throw ShortcutParseError.unknownModifier(token)
            }
            modifiers.insert(canonical)
        }

        let keyToken = tokens.last!
        let canonicalKey = keyAliases[keyToken] ?? keyToken
        guard validKeys.contains(canonicalKey) else {
            throw ShortcutParseError.unknownKey(keyToken)
        }
        return ShortcutSpec(key: canonicalKey, modifiers: modifiers)
    }

    /// Human-readable form, e.g. "⌃⌥⇧⌘O", matching what the Recorder displays.
    var displayString: String {
        let ordered: [(modifier: String, symbol: String)] = [
            ("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘"), ("fn", "fn"),
        ]
        let prefix = ordered
            .filter { modifiers.contains($0.modifier) }
            .map(\.symbol)
            .joined()
        return prefix + keyDisplayString
    }

    private var keyDisplayString: String {
        switch key {
        case "space": "Space"
        case "tab": "⇥"
        case "return": "↩"
        case "escape": "⎋"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        default: key.uppercased()
        }
    }
}

enum ShortcutParseError: LocalizedError {
    case empty
    case unknownModifier(String)
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "shortcut must not be empty"
        case .unknownModifier(let token):
            "unknown modifier \"\(token)\""
        case .unknownKey(let token):
            "unknown key \"\(token)\""
        }
    }
}
