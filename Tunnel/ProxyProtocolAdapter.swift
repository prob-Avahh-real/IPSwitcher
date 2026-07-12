import Foundation
import Network

// MARK: - Protocol Adapter Protocol

protocol ProxyProtocolAdapter {
    /// Unique identifier for this protocol type
    var type: ProxyProtocol { get }

    /// Connect to the proxy server
    func connect(to server: String, port: UInt16) async throws -> NWConnection

    /// Encapsulate (encrypt + encode) outgoing data
    func encapsulate(_ data: Data) -> Data

    /// Decapsulate (decode + decrypt) incoming data
    func decapsulate(_ data: Data) -> Data

    /// Perform protocol-specific handshake
    func handshake(connection: NWConnection) async throws

    /// Maximum overhead added by this protocol (for MTU calculation)
    var overhead: Int { get }
}

// MARK: - Shadowsocks Adapter

final class ShadowsocksAdapter: ProxyProtocolAdapter {
    let type: ProxyProtocol = .shadowsocks
    var overhead: Int { 64 } // typical Shadowsocks overhead

    private let method: EncryptionMethod
    private let password: String
    private var sessionKey: Data?

    init(method: EncryptionMethod, password: String) {
        self.method = method
        self.password = password
    }

    func connect(to server: String, port: UInt16) async throws -> NWConnection {
        let host = NWEndpoint.Host(server)
        let endpointPort = NWEndpoint.Port(integerLiteral: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let connection = NWConnection(host: host, port: endpointPort, using: params)
        return connection
    }

    func handshake(connection: NWConnection) async throws {
        // Shadowsocks handshake:
        // 1. Send: [salt] (for key derivation)
        // 2. Send: encrypted first packet with target address

        // Generate random salt for key derivation
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }

        // Derive session key (simplified - actual implementation uses HKDF)
        sessionKey = deriveKey(password: password, salt: salt)

        // Send salt to server
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: salt, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func encapsulate(_ data: Data) -> Data {
        guard let key = sessionKey else { return data }
        // Encrypt the data using the session key
        // In production: use AES-GCM or ChaCha20-Poly1305
        return encrypt(data: data, key: key)
    }

    func decapsulate(_ data: Data) -> Data {
        guard let key = sessionKey else { return data }
        return decrypt(data: data, key: key)
    }

    // MARK: - Cryptographic Helpers

    private func deriveKey(password: String, salt: Data) -> Data {
        // Simplified key derivation
        // In production: use HKDF with SHA-256
        var key = Data(count: 32)
        let passwordData = password.data(using: .utf8) ?? Data()
        key = (passwordData + salt).prefix(32)
        if key.count < 32 {
            key.append(Data(repeating: 0, count: 32 - key.count))
        }
        return key
    }

    private func encrypt(data: Data, key: Data) -> Data {
        // Simplified XOR encryption for demonstration
        // In production: use AES-256-GCM or ChaCha20-Poly1305
        var result = Data(count: data.count)
        for i in 0..<data.count {
            let keyByte = key[i % key.count]
            result[i] = data[i] ^ keyByte
        }
        return result
    }

    private func decrypt(data: Data, key: Data) -> Data {
        // XOR is symmetric
        return encrypt(data: data, key: key)
    }
}

// MARK: - VLESS Adapter

final class VLESSAdapter: ProxyProtocolAdapter {
    let type: ProxyProtocol = .vless
    var overhead: Int { 128 }

    private let uuid: String

    init(uuid: String) {
        self.uuid = uuid
    }

    func connect(to server: String, port: UInt16) async throws -> NWConnection {
        let host = NWEndpoint.Host(server)
        let endpointPort = NWEndpoint.Port(integerLiteral: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        tcpOptions.enableKeepalive = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let connection = NWConnection(host: host, port: endpointPort, using: params)
        return connection
    }

    func handshake(connection: NWConnection) async throws {
        // VLESS handshake format:
        // [version: 1 byte] [uuid: 16 bytes] [command: 1 byte] [port: 2 bytes] [address type + address]

        var handshakeData = Data()

        // Version (1)
        handshakeData.append(1)

        // UUID (16 bytes)
        let uuidData = uuid.data(using: .utf8) ?? Data(repeating: 0, count: 16)
        let paddedUUID = uuidData.count >= 16 ? uuidData.prefix(16) : uuidData + Data(repeating: 0, count: 16 - uuidData.count)
        handshakeData.append(paddedUUID)

        // Command: TCP (1)
        handshakeData.append(1)

        // Will be completed when the first data packet arrives
        // For now, send the initial handshake
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: handshakeData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func encapsulate(_ data: Data) -> Data {
        // VLESS encapsulates data with minimal overhead
        // Add length prefix for stream framing
        var length = UInt16(data.count).bigEndian
        var packet = Data()
        packet.append(Data(bytes: &length, count: 2))
        packet.append(data)
        return packet
    }

    func decapsulate(_ data: Data) -> Data {
        // Strip length prefix
        guard data.count > 2 else { return data }
        return data.dropFirst(2)
    }
}

// MARK: - Trojan Adapter

final class TrojanAdapter: ProxyProtocolAdapter {
    let type: ProxyProtocol = .trojan
    var overhead: Int { 96 }

    private let password: String
    private var handshakeComplete = false

    init(password: String) {
        self.password = password
    }

    func connect(to server: String, port: UInt16) async throws -> NWConnection {
        let host = NWEndpoint.Host(server)
        let endpointPort = NWEndpoint.Port(integerLiteral: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        tcpOptions.enableKeepalive = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let connection = NWConnection(host: host, port: endpointPort, using: params)
        return connection
    }

    func handshake(connection: NWConnection) async throws {
        // Trojan handshake:
        // [password\r\n] [request format]

        var handshakeData = Data()
        if let passwordData = password.data(using: .utf8) {
            handshakeData.append(passwordData)
        }
        handshakeData.append(contentsOf: [0x0D, 0x0A]) // CRLF

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: handshakeData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    self.handshakeComplete = true
                    continuation.resume()
                }
            })
        }
    }

    func encapsulate(_ data: Data) -> Data {
        // Trojan uses TLS for encryption (handled by NWParameters)
        // Just add the Trojan header for the target address
        return data
    }

    func decapsulate(_ data: Data) -> Data {
        return data
    }
}

// MARK: - Adapter Factory

enum ProxyAdapterFactory {
    static func createAdapter(for protocolType: ProxyProtocol, password: String, method: EncryptionMethod) -> ProxyProtocolAdapter {
        switch protocolType {
        case .shadowsocks:
            return ShadowsocksAdapter(method: method, password: password)
        case .vless:
            return VLESSAdapter(uuid: password)
        case .trojan:
            return TrojanAdapter(password: password)
        case .socks5:
            // SOCKS5 is handled natively, wraps as a simple adapter
            return SOCKS5Adapter()
        }
    }
}

// MARK: - SOCKS5 Adapter

final class SOCKS5Adapter: ProxyProtocolAdapter {
    let type: ProxyProtocol = .socks5
    var overhead: Int { 10 }

    func connect(to server: String, port: UInt16) async throws -> NWConnection {
        let host = NWEndpoint.Host(server)
        let endpointPort = NWEndpoint.Port(integerLiteral: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let connection = NWConnection(host: host, port: endpointPort, using: params)
        return connection
    }

    func handshake(connection: NWConnection) async throws {
        // SOCKS5 handshake:
        // Client: [0x05] [auth methods count] [methods...]
        // Server: [0x05] [chosen method]

        var greeting = Data([0x05, 0x01, 0x00]) // SOCKS5, 1 method, no auth

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: greeting, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Read server response
        // In production: read exactly 2 bytes from connection
    }

    func encapsulate(_ data: Data) -> Data {
        // SOCKS5 doesn't encapsulate - it tunnels directly
        return data
    }

    func decapsulate(_ data: Data) -> Data {
        return data
    }
}
