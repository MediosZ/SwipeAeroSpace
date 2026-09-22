import Foundation
import XCTest
@testable import ConfigurationSupport

final class ConfigurationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var file: URL { directory.appendingPathComponent("config.toml") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "SwipeAeroSpaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func load(_ text: String) throws -> Configuration {
        try text.write(to: file, atomically: true, encoding: .utf8)
        return Configuration(url: file)
    }

    func testMissingFileUsesSavedAndBuiltInValues() {
        let config = Configuration(url: file)
        XCTAssertNil(config.errorMessage)
        defaults.set(2.5, forKey: "threshold")
        let threshold = ConfigStorage(wrappedValue: 1.0, "threshold", store: defaults, configuration: config)
        XCTAssertEqual(threshold.wrappedValue, 2.5)
        threshold.projectedValue.wrappedValue = 3.0
        XCTAssertEqual(defaults.double(forKey: "threshold"), 3.0)
        XCTAssertEqual(ConfigStorage(wrappedValue: "Three", "fingers", store: defaults,
                                     configuration: config).wrappedValue, "Three")
    }

    func testOverridesPreserveSavedPreferencesAndUnspecifiedSettings() throws {
        defaults.set(2.5, forKey: "threshold")
        defaults.set(true, forKey: "wrap")
        let config = try load("threshold = 0.75\nnatural = false")
        XCTAssertNil(config.errorMessage)
        let threshold = ConfigStorage(wrappedValue: 1.0, "threshold", store: defaults, configuration: config)
        XCTAssertEqual(threshold.wrappedValue, 0.75)
        threshold.projectedValue.wrappedValue = 4.0
        XCTAssertEqual(threshold.wrappedValue, 0.75)
        XCTAssertEqual(defaults.double(forKey: "threshold"), 2.5)
        XCTAssertTrue(ConfigStorage(wrappedValue: false, "wrap", store: defaults,
                                    configuration: config).wrappedValue)
        XCTAssertFalse(ConfigStorage(wrappedValue: true, "natural", store: defaults,
                                     configuration: config).wrappedValue)
        try FileManager.default.removeItem(at: file)
        let nextLaunch = Configuration(url: file)
        XCTAssertEqual(ConfigStorage(wrappedValue: 1.0, "threshold", store: defaults,
                                     configuration: nextLaunch).wrappedValue, 2.5)
    }

    func testAllSupportedKeysAndTOMLSyntax() throws {
        let values = try Configuration.parse("""
        # Quoted keys, literal strings, comments, and scientific notation are TOML.
        "threshold" = 1e0
        wrap = true # inline comment
        natural = false
        skip-empty = true
        fingers = 'Four'
        multiSwipe = false
        maxSteps = 9
        swipeUpOverview = false
        swipeUpFingers = "Three"
        show-empty-workspaces = true
        menuBarExtraIsInserted = true
        """)
        XCTAssertEqual(values.count, 11)
        XCTAssertEqual(values["threshold"] as? Double, 1.0)
        XCTAssertEqual(values["maxSteps"] as? Int, 9)
        XCTAssertEqual(values["fingers"] as? String, "Four")
    }

    func testIntegerThreshold() throws {
        XCTAssertEqual(try Configuration.parse("threshold = 2")["threshold"] as? Double, 2.0)
    }

    func testEmptyFileHasNoOverrides() throws {
        let config = try load("# No overrides\n")
        XCTAssertTrue(config.values.isEmpty)
        XCTAssertNil(config.errorMessage)
    }

    func testInvalidFilesAreRejectedAtomically() throws {
        for invalid in [
            "wrap =", "wrap = true\nwrap = false", "wrap = 'true'", "maxSteps = 2.5",
            "maxSteps = 1", "maxSteps = 10", "threshold = 0", "threshold = -1.0",
            "threshold = nan", "threshold = inf", "fingers = 'Five'", "swipeUpFingers = 3",
            "typo = true", "[unexpected]\nwrap = true",
        ] {
            let config = try load("natural = false\n" + invalid)
            XCTAssertNotNil(config.errorMessage, invalid)
            XCTAssertTrue(config.values.isEmpty, invalid)
        }
    }

    func testUnreadableFileReportsAnError() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let config = Configuration(url: file)
        XCTAssertTrue(config.values.isEmpty)
        XCTAssertNotNil(config.errorMessage)
    }

    func testRequestedPath() {
        XCTAssertEqual(Configuration.fileURL.path,
                       FileManager.default.homeDirectoryForCurrentUser.path + "/.config/swipeareospace/config.toml")
    }
}
