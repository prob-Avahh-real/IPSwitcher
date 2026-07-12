import Foundation
import Network

/// Configuration parsed from provider options and passed to the tunnel
struct TunnelConfiguration {
    let serverAddress: String
    let port: UInt16
    let method: EncryptionMethod
    let password: String
    let protocolType: ProxyProtocol
    let dnsServers: [String]
    let mtu: Int
    let nodeId: String
    let region: String

    init(from providerOptions: [String: NSObject]?) throws {
        guard let options = providerOptions else {
            throw TunnelConfigError.missingOptions
        }

        guard let configData = options["tunnelConfig"] as? Data else {
            throw TunnelConfigError.missingConfig
        }

        let config = try JSONDecoder().decode(TunnelConfigPayload.self, from: configData)

        self.serverAddress = config.serverAddress
        self.port = config.port
        self.method = config.method
        self.password = config.password
        self.protocolType = config.protocolType
        self.dnsServers = config.dnsServers
        self.mtu = config.mtu
        self.nodeId = options["nodeId"] as? String ?? "unknown"
        self.region = options["region"] as? String ?? "unknown"
    }
}

private struct TunnelConfigPayload: Codable {
    let serverAddress: String
    let port: UInt16
    let method: EncryptionMethod
    let password: String
    let protocolType: ProxyProtocol
    let dnsServers: [String]
    let mtu: Int
}

enum TunnelConfigError: Error, LocalizedError {
    case missingOptions
    case missingConfig
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .missingOptions:
            return "Tunnel started without provider options"
        case .missingConfig:
            return "Tunnel config not found in provider options"
        case .invalidConfig(let detail):
            return "Invalid tunnel config: \(detail)"
        }
    }
}
