import SwiftUI

/// Preserves AppStorage's bindings and updates for settings absent from the file.
@propertyWrapper
struct ConfigStorage<Value>: DynamicProperty {
    @AppStorage private var savedValue: Value
    private let key: String
    @ObservedObject private var configuration: Configuration

    private init(key: String, storage: AppStorage<Value>, configuration: Configuration) {
        self.key = key
        self._savedValue = storage
        self.configuration = configuration
    }

    var wrappedValue: Value {
        get { configuration.values[key] as? Value ?? savedValue }
        nonmutating set {
            guard configuration.values[key] == nil else { return }
            savedValue = newValue
        }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension ConfigStorage where Value == Bool {
    init(wrappedValue: Bool, _ key: String, store: UserDefaults? = nil,
         configuration: Configuration = .shared) {
        self.init(key: key, storage: AppStorage(wrappedValue: wrappedValue, key, store: store),
                  configuration: configuration)
    }
}

extension ConfigStorage where Value == Double {
    init(wrappedValue: Double, _ key: String, store: UserDefaults? = nil,
         configuration: Configuration = .shared) {
        self.init(key: key, storage: AppStorage(wrappedValue: wrappedValue, key, store: store),
                  configuration: configuration)
    }
}

extension ConfigStorage where Value == Int {
    init(wrappedValue: Int, _ key: String, store: UserDefaults? = nil,
         configuration: Configuration = .shared) {
        self.init(key: key, storage: AppStorage(wrappedValue: wrappedValue, key, store: store),
                  configuration: configuration)
    }
}

extension ConfigStorage where Value == String {
    init(wrappedValue: String, _ key: String, store: UserDefaults? = nil,
         configuration: Configuration = .shared) {
        self.init(key: key, storage: AppStorage(wrappedValue: wrappedValue, key, store: store),
                  configuration: configuration)
    }
}
