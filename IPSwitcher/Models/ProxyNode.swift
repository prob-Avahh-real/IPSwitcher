import Foundation

// MARK: - Encryption Method

enum EncryptionMethod: String, Codable, CaseIterable {
    case aes256GCM = "aes-256-gcm"
    case aes128GCM = "aes-128-gcm"
    case chacha20IETF = "chacha20-ietf"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"
    case plain = "none"

    var recommended: Bool {
        switch self {
        case .aes256GCM, .chacha20IETFPoly1305: return true
        default: return false
        }
    }
}

// MARK: - Proxy Protocol

enum ProxyProtocol: String, Codable, CaseIterable, Identifiable {
    case shadowsocks = "shadowsocks"
    case vless = "vless"
    case trojan = "trojan"
    case socks5 = "socks5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shadowsocks: return "Shadowsocks"
        case .vless: return "VLESS"
        case .trojan: return "Trojan"
        case .socks5: return "SOCKS5"
        }
    }
}

// MARK: - Proxy Node

struct ProxyNode: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let serverAddress: String
    let port: UInt16
    let method: EncryptionMethod
    let password: String
    let protocolType: ProxyProtocol
    let region: String
    let city: String
    let provider: String
    let bandwidth: Int            // Mbps
    let features: [NodeFeature]

    // Runtime state (not persisted in config)
    var latency: TimeInterval?
    var isOnline: Bool = true
    var load: Double = 0.0        // 0.0 ~ 1.0
    var isFavorite: Bool = false

    var regionFlag: String {
        RegionFlags.flag(for: region)
    }

    var displayLatency: String {
        guard let latency else { return "---" }
        return "\(Int(latency * 1000))ms"
    }

    var displayName: String {
        "\(regionFlag) \(name)"
    }
}

// MARK: - Node Feature

enum NodeFeature: String, Codable, CaseIterable {
    case streaming = "streaming"
    case social = "social"
    case gaming = "gaming"
    case torrent = "torrent"
    case chat = "chat"

    var displayName: String {
        switch self {
        case .streaming: return "流媒体"
        case .social: return "社交平台"
        case .gaming: return "游戏"
        case .torrent: return "下载"
        case .chat: return "即时通讯"
        }
    }
}

// MARK: - Node Selection Strategy

enum SelectionStrategy: Equatable {
    case lowestLatency
    case specificRegion(String)
    case random
    case byFeature(NodeFeature)
}

// MARK: - Tunnel Configuration

struct TunnelConfig: Codable {
    let serverAddress: String
    let port: UInt16
    let method: EncryptionMethod
    let password: String
    let protocolType: ProxyProtocol
    let dnsServers: [String]
    let mtu: Int

    static let defaultDNS = ["1.1.1.1", "8.8.8.8"]
    static let defaultMTU = 1500

    init(node: ProxyNode) {
        self.serverAddress = node.serverAddress
        self.port = node.port
        self.method = node.method
        self.password = node.password
        self.protocolType = node.protocolType
        self.dnsServers = Self.defaultDNS
        self.mtu = Self.defaultMTU
    }
}

// MARK: - Proxy Rule

struct ProxyRule: Codable, Identifiable, Equatable {
    var id: String { UUID().uuidString }
    let type: RuleType
    let value: String          // IP CIDR, domain, or app bundle ID
    let action: RuleAction
    let note: String?

    enum RuleType: String, Codable, CaseIterable {
        case domain = "domain"
        case ipCIDR = "ip_cidr"
        case appBundle = "app_bundle"
    }

    enum RuleAction: String, Codable, CaseIterable {
        case proxy = "proxy"
        case direct = "direct"
        case drop = "drop"
    }
}

// MARK: - IP Information

struct IPInfo: Codable, Equatable {
    let ip: String
    let country: String
    let countryCode: String
    let region: String
    let city: String
    let isp: String
    let latitude: Double
    let longitude: Double
    let timezone: String

    var flag: String {
        RegionFlags.flag(for: countryCode.lowercased())
    }

    var locationString: String {
        [flag, city, region, country].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static let mock = IPInfo(
        ip: "203.0.113.42",
        country: "日本",
        countryCode: "jp",
        region: "东京都",
        city: "东京",
        isp: "ExampleNet",
        latitude: 35.6762,
        longitude: 139.6503,
        timezone: "Asia/Tokyo"
    )
}

// MARK: - Connection Statistics

struct ConnectionStats: Equatable {
    var bytesReceived: UInt64 = 0
    var bytesSent: UInt64 = 0
    var connectedSince: Date?
    var packetsProcessed: UInt64 = 0

    var receivedFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesReceived), countStyle: .file)
    }

    var sentFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesSent), countStyle: .file)
    }

    var durationFormatted: String {
        guard let start = connectedSince else { return "00:00:00" }
        let interval = Date().timeIntervalSince(start)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - Errors

enum VPNError: LocalizedError {
    case notConfigured
    case tunnelStartFailed(Error)
    case tunnelStopFailed(Error)
    case configurationInvalid(String)
    case nodeUnavailable(String)
    case keychainError(OSStatus)
    case permissionDenied
    case featureNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "VPN 未配置"
        case .tunnelStartFailed(let error):
            return "隧道启动失败: \(error.localizedDescription)"
        case .tunnelStopFailed(let error):
            return "隧道停止失败: \(error.localizedDescription)"
        case .configurationInvalid(let detail):
            return "配置无效: \(detail)"
        case .nodeUnavailable(let name):
            return "节点不可用: \(name)"
        case .keychainError(let status):
            return "钥匙串错误: \(status)"
        case .permissionDenied:
            return "权限被拒绝，请在设置中允许 VPN 配置"
        case .featureNotAvailable(let feature):
            return "功能不可用: \(feature)"
        }
    }
}

// MARK: - Region Flags

enum RegionFlags {
    static func flag(for regionCode: String) -> String {
        let base: UInt32 = 127397
        let code = regionCode.uppercased()
        guard code.count == 2 else { return "🌍" }
        let scalars = code.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            UnicodeScalar(base + scalar.value)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let vpnStatusDidChange = Notification.Name("vpnStatusDidChange")
    static let nodeListDidUpdate = Notification.Name("nodeListDidUpdate")
    static let trafficDidUpdate = Notification.Name("trafficDidUpdate")
    static let nodeLatencyDidUpdate = Notification.Name("nodeLatencyDidUpdate")
}
