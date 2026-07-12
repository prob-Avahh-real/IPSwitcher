import Foundation

final class ConfigService {
    static let shared = ConfigService()

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Subscription Import

    /// Import nodes from a subscription URL
    /// Supports: base64-encoded JSON, plain JSON, SIP008 (Shadowsocks)
    func importFromSubscription(url: URL) async throws -> [ProxyNode] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("IPSwitcher/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw ConfigError.fetchFailed
        }

        return try parseSubscriptionData(data)
    }

    /// Parse subscription data, trying multiple formats
    private func parseSubscriptionData(_ data: Data) throws -> [ProxyNode] {
        // Try 1: Plain JSON
        if let nodes = try? decoder.decode([ProxyNode].self, from: data) {
            return nodes
        }

        // Try 2: Base64-encoded JSON
        if let decodedString = String(data: data, encoding: .utf8)
            .flatMap({ Data(base64Encoded: $0) }),
            let nodes = try? decoder.decode([ProxyNode].self, from: decodedString) {
            return nodes
        }

        // Try 3: SIP008 format (Shadowsocks)
        if let sip008 = try? decoder.decode(SIP008Config.self, from: data) {
            return sip008.toProxyNodes()
        }

        // Try 4: One-per-line base64 (Surge/Clash format)
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var nodes: [ProxyNode] = []
            for line in lines {
                if let node = try? parseSurgeLine(line) {
                    nodes.append(node)
                }
            }
            if !nodes.isEmpty {
                return nodes
            }
        }

        throw ConfigError.unsupportedFormat
    }

    /// Parse a single Surge/Clash-style proxy line
    private func parseSurgeLine(_ line: String) throws -> ProxyNode {
        // Format: server:port:method:password
        // or: ss://BASE64
        if line.hasPrefix("ss://") {
            return try parseShadowsocksURI(String(line.dropFirst(5)))
        }

        let parts = line.split(separator: ":").map(String.init)
        guard parts.count >= 4 else {
            throw ConfigError.parseFailed(line)
        }

        return ProxyNode(
            id: UUID().uuidString,
            name: "Imported \(parts[0])",
            serverAddress: parts[0],
            port: UInt16(parts[1]) ?? 443,
            method: EncryptionMethod(rawValue: parts[2]) ?? .aes256GCM,
            password: parts[3],
            protocolType: .shadowsocks,
            region: "unknown",
            city: "",
            provider: "Subscription",
            bandwidth: 100,
            features: [.social]
        )
    }

    /// Parse ss:// URI scheme
    private func parseShadowsocksURI(_ encoded: String) throws -> ProxyNode {
        // Format: method:password@server:port  (base64 encoded after ss://)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8)
        else {
            throw ConfigError.parseFailed(encoded)
        }

        let parts = decoded.split(separator: "@").map(String.init)
        guard parts.count == 2 else {
            throw ConfigError.parseFailed(decoded)
        }

        let methodPassword = parts[0].split(separator: ":").map(String.init)
        let serverPort = parts[1].split(separator: ":").map(String.init)

        guard methodPassword.count >= 2, serverPort.count >= 2 else {
            throw ConfigError.parseFailed(decoded)
        }

        return ProxyNode(
            id: UUID().uuidString,
            name: "Imported \(serverPort[0])",
            serverAddress: serverPort[0],
            port: UInt16(serverPort[1]) ?? 443,
            method: EncryptionMethod(rawValue: methodPassword[0]) ?? .aes256GCM,
            password: methodPassword[1],
            protocolType: .shadowsocks,
            region: "unknown",
            city: "",
            provider: "Subscription",
            bandwidth: 100,
            features: [.social]
        )
    }

    // MARK: - Configuration Import/Export

    /// Export current configuration as JSON data
    func exportConfig(nodes: [ProxyNode], config: AppConfig) throws -> Data {
        let export = ExportConfig(nodes: nodes, config: config, version: 2)
        return try encoder.encode(export)
    }

    /// Import configuration from JSON data
    func importConfig(from data: Data) throws -> (nodes: [ProxyNode], config: AppConfig) {
        let export = try decoder.decode(ExportConfig.self, from: data)
        return (export.nodes, export.config)
    }

    // MARK: - Validation

    func validateNode(_ node: ProxyNode) -> Bool {
        guard !node.serverAddress.isEmpty else { return false }
        guard node.port > 0 && node.port <= 65535 else { return false }
        guard !node.password.isEmpty else { return false }
        return true
    }

    func validateAllNodes(_ nodes: [ProxyNode]) -> [String: Bool] {
        var results: [String: Bool] = [:]
        for node in nodes {
            results[node.id] = validateNode(node)
        }
        return results
    }
}

// MARK: - Supporting Types

struct SIP008Config: Codable {
    let version: Int?
    let servers: [SIP008Server]?

    struct SIP008Server: Codable {
        let id: String?
        let remarks: String?
        let server: String
        let serverPort: Int
        let method: String
        let password: String
        let `protocol`: String?
        let obfs: String?
    }

    func toProxyNodes() -> [ProxyNode] {
        guard let servers = servers else { return [] }
        return servers.map { server in
            ProxyNode(
                id: server.id ?? UUID().uuidString,
                name: server.remarks ?? server.server,
                serverAddress: server.server,
                port: UInt16(server.serverPort),
                method: EncryptionMethod(rawValue: server.method) ?? .aes256GCM,
                password: server.password,
                protocolType: .shadowsocks,
                region: RegionDetector.detect(from: server.server) ?? "unknown",
                city: "",
                provider: "Subscription",
                bandwidth: 100,
                features: [.social]
            )
        }
    }
}

struct ExportConfig: Codable {
    let nodes: [ProxyNode]
    let config: AppConfig
    let version: Int
}

enum ConfigError: LocalizedError {
    case fetchFailed
    case unsupportedFormat
    case parseFailed(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "无法获取订阅内容"
        case .unsupportedFormat:
            return "不支持的订阅格式"
        case .parseFailed(let detail):
            return "解析失败: \(detail)"
        case .invalidURL:
            return "无效的 URL"
        }
    }
}

// MARK: - Region Detector

enum RegionDetector {
    /// Simple region detection based on server address keywords
    static func detect(from address: String) -> String? {
        let patterns: [(keyword: String, region: String)] = [
            ("jp", "jp"), ("tokyo", "jp"), ("日本", "jp"),
            ("hk", "hk"), ("hongkong", "hk"), ("香港", "hk"),
            ("sg", "sg"), ("singapore", "sg"), ("新加坡", "sg"),
            ("us", "us"), ("la", "us"), ("los-angeles", "us"),
            ("losangeles", "us"), ("unitedstates", "us"),
            ("kr", "kr"), ("korea", "kr"), ("韩国", "kr"),
            ("tw", "tw"), ("taiwan", "tw"), ("台湾", "tw"),
            ("uk", "gb"), ("london", "gb"), ("英国", "gb"),
            ("de", "de"), ("germany", "de"), ("frankfurt", "de"),
            ("au", "au"), ("australia", "au"), ("sydney", "au"),
            ("ca", "ca"), ("canada", "ca"),
        ]

        let lower = address.lowercased()
        for (keyword, region) in patterns {
            if lower.contains(keyword) {
                return region
            }
        }
        return nil
    }
}
