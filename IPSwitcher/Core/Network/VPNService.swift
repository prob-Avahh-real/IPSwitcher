import Foundation
import NetworkExtension
import Combine

final class VPNService: ObservableObject {
    static let shared = VPNService()

    // MARK: - Published State

    @Published private(set) var connectionStatus: NEVPNStatus = .invalid
    @Published private(set) var currentNode: ProxyNode?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var stats = ConnectionStats()
    @Published private(set) var isConfigLoaded = false
    @Published private(set) var lastError: VPNError?

    // MARK: - Private

    private var manager: NEVPNManager?
    private var statusObserver: NSObjectProtocol?
    private var trafficTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        observeVPNStatus()
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        trafficTimer?.invalidate()
    }

    // MARK: - Configuration

    /// Load VPN configuration from system preferences
    /// This triggers the system permission dialog on first use
    @MainActor
    func loadConfiguration() async throws {
        let mgr = NEVPNManager.shared()

        // Load existing preferences
        try await mgr.loadFromPreferences()

        // If no protocol configuration exists, create one
        if mgr.protocolConfiguration == nil {
            let protocolConfig = NEVPNProtocolIKEv2()
            protocolConfig.serverAddress = "127.0.0.1" // Will be overridden by NEPacketTunnelProvider
            protocolConfig.authenticationMethod = .none
            protocolConfig.useExtendedAuthentication = false
            protocolConfig.disconnectOnSleep = false

            mgr.protocolConfiguration = protocolConfig
        }

        mgr.isEnabled = true
        mgr.localizedDescription = "IP Switcher"

        // Save to preferences
        try await mgr.saveToPreferences()

        self.manager = mgr
        self.isConfigLoaded = true
        self.connectionStatus = mgr.connection.status
    }

    /// Check and request VPN permission if needed
    @MainActor
    func ensurePermission() async throws -> Bool {
        let mgr = NEVPNManager.shared()
        try await mgr.loadFromPreferences()

        // If we can load preferences without error, permission is granted
        return true
    }

    // MARK: - Connection

    /// Connect to a specific proxy node
    @MainActor
    func connect(to node: ProxyNode) async throws {
        guard isConfigLoaded, let manager = manager else {
            throw VPNError.notConfigured
        }

        // Encode node configuration for the tunnel provider
        let config = TunnelConfig(node: node)
        let configData = try JSONEncoder().encode(config)

        let options: [String: NSObject] = [
            "tunnelConfig": configData as NSObject,
            "nodeId": node.id as NSObject,
            "region": node.region as NSObject,
        ]

        // Store password reference for the tunnel
        let passwordRef = try KeychainManager.store(password: node.password)

        // Update protocol configuration
        if let protoConfig = manager.protocolConfiguration {
            protoConfig.serverAddress = node.serverAddress
            protoConfig.passwordReference = passwordRef
        }

        try await manager.saveToPreferences()

        // Start the tunnel
        do {
            try manager.connection.startVPNTunnel(options: options)
            self.currentNode = node
            self.connectedSince = Date()
            self.connectionStatus = .connecting

            // Record connection
            UserDefaultsManager.shared.recordConnection(
                nodeId: node.id,
                region: node.region
            )
            UserDefaultsManager.shared.lastConnectedNodeId = node.id

            // Start traffic monitoring
            startTrafficMonitoring()

            await NodeManager.shared.setActiveNode(node)
        } catch {
            self.lastError = VPNError.tunnelStartFailed(error)
            throw VPNError.tunnelStartFailed(error)
        }
    }

    /// Disconnect the VPN tunnel
    @MainActor
    func disconnect() {
        guard let manager = manager else { return }

        manager.connection.stopVPNTunnel()
        self.currentNode = nil
        self.stats = ConnectionStats()
        self.connectedSince = nil
        self.connectionStatus = .disconnected

        stopTrafficMonitoring()

        Task { await NodeManager.shared.setActiveNode(nil) }
    }

    /// Switch to a different node
    /// Brief disconnect then reconnect to the new node
    @MainActor
    func switchTo(node: ProxyNode) async throws {
        // Disconnect first
        disconnect()

        // Small delay to ensure clean state
        try await Task.sleep(nanoseconds: 500_000_000)

        // Connect to new node
        try await connect(to: node)
    }

    /// Reconnect to the last used node
    @MainActor
    func reconnect() async throws {
        guard let nodeId = UserDefaultsManager.shared.lastConnectedNodeId else {
            throw VPNError.notConfigured
        }

        let nodes = UserDefaultsManager.shared.savedNodes
        guard let node = nodes.first(where: { $0.id == nodeId }) else {
            throw VPNError.nodeUnavailable(nodeId)
        }

        try await connect(to: node)
    }

    /// Quick connect to the best available node
    @MainActor
    func quickConnect() async throws {
        let strategy: SelectionStrategy = .lowestLatency
        let node = try await NodeManager.shared.selectNode(strategy: strategy)
        try await connect(to: node)
    }

    // MARK: - Status Observation

    private func observeVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection
            else { return }

            self.connectionStatus = connection.status

            switch connection.status {
            case .connected:
                self.connectedSince = self.connectedSince ?? Date()
                NotificationCenter.default.post(name: .vpnStatusDidChange, object: nil)

            case .disconnected, .invalid:
                self.currentNode = nil
                self.stats = ConnectionStats()
                self.connectedSince = nil
                self.stopTrafficMonitoring()
                NotificationCenter.default.post(name: .vpnStatusDidChange, object: nil)

            case .reasserting:
                // Connection is being restored
                break

            default:
                break
            }
        }
    }

    // MARK: - Traffic Monitoring

    private func startTrafficMonitoring() {
        trafficTimer?.invalidate()
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollTrafficStats()
        }
    }

    private func stopTrafficMonitoring() {
        trafficTimer?.invalidate()
        trafficTimer = nil
    }

    private func pollTrafficStats() {
        // NOTE: In a real implementation, this would read from
        // the tunnel provider via IPC. For now, we simulate.
        // The actual implementation would use CFMessagePort or
        // a shared container to read stats from the tunnel.
        stats.packetsProcessed += 1
        NotificationCenter.default.post(name: .trafficDidUpdate, object: nil)
    }

    // MARK: - Tunnel IPC

    /// Send a message to the running tunnel provider
    /// Used for hot-reloading configuration without restarting the tunnel
    func sendMessageToTunnel(_ message: TunnelMessage) async throws -> Data? {
        // In production, this would use:
        // 1. CFMessagePortCreateRemote to connect to the tunnel's port
        // 2. CFMessagePortSendRequest to send the message
        // 3. Parse the response

        // For now, reconnection is the supported approach
        throw VPNError.featureNotAvailable("隧道 IPC (需要重新连接)")
    }
}

// MARK: - Tunnel IPC Messages

enum TunnelMessage: Codable {
    case switchNode(config: TunnelConfig)
    case updateRules(rules: [ProxyRule])
    case getStats
    case ping
}

// MARK: - App Coordinator

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    @Published var isOnboarding = false
    @Published var showError = false
    @Published var errorMessage: String?

    private init() {}

    func checkFirstLaunch() {
        if !UserDefaultsManager.shared.hasCompletedOnboarding {
            isOnboarding = true
        }
    }

    func completeOnboarding() {
        UserDefaultsManager.shared.hasCompletedOnboarding = true
        isOnboarding = false
    }

    func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
