import Foundation
import Combine

/// Type-safe wrapper around UserDefaults for app configuration
@propertyWrapper
struct UserDefault<T: Codable> {
    let key: String
    let defaultValue: T

    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else {
                return defaultValue
            }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}

final class UserDefaultsManager: ObservableObject {
    static let shared = UserDefaultsManager()

    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Stored Properties

    @UserDefault("appConfig", defaultValue: AppConfig())
    var appConfig: AppConfig {
        didSet { objectWillChange.send() }
    }

    @UserDefault("savedNodes", defaultValue: [])
    var savedNodes: [ProxyNode] {
        didSet { objectWillChange.send() }
    }

    @UserDefault("favoriteNodeIds", defaultValue: [])
    var favoriteNodeIds: [String] {
        didSet { objectWillChange.send() }
    }

    @UserDefault("lastConnectedNodeId", defaultValue: nil)
    var lastConnectedNodeId: String?

    @UserDefault("connectionHistory", defaultValue: [])
    var connectionHistory: [ConnectionRecord] {
        didSet { objectWillChange.send() }
    }

    @UserDefault("totalTrafficBytes", defaultValue: 0)
    var totalTrafficBytes: UInt64

    @UserDefault("appLaunchCount", defaultValue: 0)
    var appLaunchCount: Int

    @UserDefault("hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool

    // MARK: - Methods

    func saveNodes(_ nodes: [ProxyNode]) {
        savedNodes = nodes
        NotificationCenter.default.post(name: .nodeListDidUpdate, object: nil)
    }

    func toggleFavorite(nodeId: String) {
        if favoriteNodeIds.contains(nodeId) {
            favoriteNodeIds.removeAll { $0 == nodeId }
        } else {
            favoriteNodeIds.append(nodeId)
        }
    }

    func isFavorite(nodeId: String) -> Bool {
        favoriteNodeIds.contains(nodeId)
    }

    func recordConnection(nodeId: String, region: String) {
        let record = ConnectionRecord(
            nodeId: nodeId,
            region: region,
            timestamp: Date()
        )
        var history = connectionHistory
        history.insert(record, at: 0)
        // Keep last 100 records
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
        connectionHistory = history
    }

    func incrementLaunchCount() {
        appLaunchCount += 1
    }

    func addTraffic(bytes: UInt64) {
        totalTrafficBytes += bytes
    }

    func resetTraffic() {
        totalTrafficBytes = 0
    }

    // MARK: - Clear Data

    func clearAllData() {
        let domain = Bundle.main.bundleIdentifier ?? "com.ipswitcher"
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        // Force reload defaults
        objectWillChange.send()
    }
}

// MARK: - Connection History Record

struct ConnectionRecord: Codable, Identifiable {
    var id: String { "\(nodeId)-\(timestamp.timeIntervalSince1970)" }
    let nodeId: String
    let region: String
    let timestamp: Date
    var duration: TimeInterval?

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}
