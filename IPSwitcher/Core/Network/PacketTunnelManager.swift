import Foundation
import NetworkExtension

/// Manages the lifecycle and communication with the Packet Tunnel Provider
final class PacketTunnelManager: ObservableObject {
    static let shared = PacketTunnelManager()

    @Published private(set) var isTunnelRunning = false
    @Published private(set) var lastError: Error?

    private let providerBundleIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.ipswitcher").tunnel"

    // MARK: - Provider Management

    /// Get the tunnel provider manager
    func getProviderManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        if let existing = managers.first {
            return existing
        }

        // Create new provider configuration
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = providerBundleIdentifier
        config.serverAddress = "IP Switcher"
        config.providerConfiguration = [:]

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = config
        manager.localizedDescription = "IP Switcher"
        manager.isEnabled = true

        try await manager.saveToPreferences()
        return manager
    }

    /// Remove all VPN configurations
    func removeAllConfigurations() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for manager in managers {
            try await manager.removeFromPreferences()
        }
        isTunnelRunning = false
    }

    // MARK: - Tunnel Communication

    /// Send a message to the running tunnel provider and get a response
    func sendMessage(_ message: Data) async throws -> Data? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        guard let manager = managers.first,
              manager.connection.status == .connected
        else {
            throw TunnelError.tunnelNotRunning
        }

        let provider = manager.connection as! NETunnelProviderSession

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try provider.sendProviderMessage(message) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: TunnelError.communicationFailed(error))
            }
        }
    }

    /// Request traffic statistics from the tunnel provider
    func requestStats() async throws -> TunnelStats? {
        let message = try JSONEncoder().encode(TunnelProviderMessage.requestStats)
        guard let response = try await sendMessage(message) else {
            return nil
        }
        return try JSONDecoder().decode(TunnelStats.self, from: response)
    }

    /// Request the tunnel to switch to a new configuration without full reconnect
    func requestConfigUpdate(_ config: TunnelConfig) async throws {
        let message = try JSONEncoder().encode(TunnelProviderMessage.updateConfig(config))
        try await sendMessage(message)
    }

    /// Request current connection status from the tunnel
    func requestStatus() async throws -> TunnelStatus? {
        let message = try JSONEncoder().encode(TunnelProviderMessage.requestStatus)
        guard let response = try await sendMessage(message) else {
            return nil
        }
        return try JSONDecoder().decode(TunnelStatus.self, from: response)
    }
}

// MARK: - IPC Protocol

enum TunnelProviderMessage: Codable {
    case requestStats
    case updateConfig(TunnelConfig)
    case requestStatus
    case ping
}

struct TunnelStats: Codable {
    let bytesReceived: UInt64
    let bytesSent: UInt64
    let packetsProcessed: UInt64
    let connectedSince: Date
}

struct TunnelStatus: Codable {
    let isConnected: Bool
    let nodeId: String
    let region: String
    let connectedAt: Date?
    let errorMessage: String?
}

// MARK: - Errors

enum TunnelError: LocalizedError {
    case tunnelNotRunning
    case communicationFailed(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tunnelNotRunning:
            return "隧道未运行"
        case .communicationFailed(let error):
            return "隧道通信失败: \(error.localizedDescription)"
        case .invalidResponse:
            return "隧道返回了无效响应"
        }
    }
}
