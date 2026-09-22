import Foundation
import TOMLKit
import os

/// A launch-time overlay. File values never replace the user's saved preferences.
struct Configuration {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/swipeareospace/config.toml")
    static let shared = Configuration()

    let values: [String: Any]
    let errorMessage: String?

    init(url: URL = Configuration.fileURL) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            values = try Self.parse(contents)
            errorMessage = nil
        } catch CocoaError.fileReadNoSuchFile {
            values = [:]
            errorMessage = nil
        } catch {
            values = [:]
            let message = "Could not load \(url.path): \(error). Using saved settings."
            errorMessage = message
            Logger(subsystem: "club.mediosz.SwipeAeroSpace", category: "Configuration")
                .error("\(message, privacy: .public)")
        }
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
                     "show-empty-workspaces", "menuBarExtraIsInserted":
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
