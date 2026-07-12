import Foundation
import Network

enum NetworkUtils {
    // MARK: - Validation

    static func isValidIPAddress(_ address: String) -> Bool {
        // IPv4
        let ipv4Regex = #"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$"#
        if let match = address.range(of: ipv4Regex, options: .regularExpression) {
            let parts = address.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts.allSatisfy { $0 >= 0 && $0 <= 255 }
        }

        // IPv6 (simplified)
        let ipv6Regex = #"^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$"#
        return address.range(of: ipv6Regex, options: .regularExpression) != nil
    }

    static func isValidDomain(_ domain: String) -> Bool {
        let regex = #"^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"#
        return domain.range(of: regex, options: .regularExpression) != nil
    }

    static func isValidCIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return false }

        let ipPart = parts[0]
        guard let prefixLength = Int(parts[1]) else { return false }

        if ipPart.contains(":") {
            // IPv6 CIDR
            return isValidIPAddress(ipPart) && prefixLength >= 0 && prefixLength <= 128
        } else {
            // IPv4 CIDR
            return isValidIPAddress(ipPart) && prefixLength >= 0 && prefixLength <= 32
        }
    }

    // MARK: - Ping

    /// Perform a TCP ping to a host:port
    static func ping(host: String, port: UInt16, timeout: TimeInterval = 3.0) async throws -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )

        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let latency = CFAbsoluteTimeGetCurrent() - start
                    connection.cancel()
                    continuation.resume(returning: latency)
                case .failed(let error):
                    connection.cancel()
                    continuation.resume(throwing: NetworkError.pingFailed(error))
                case .cancelled:
                    continuation.resume(throwing: NetworkError.pingCancelled)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global())

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                continuation.resume(throwing: NetworkError.pingTimeout)
            }
        }
    }

    // MARK: - DNS Resolution

    /// Resolve a domain to IP addresses
    static func resolveDomain(_ domain: String) async throws -> [String] {
        let host = CFHostCreateWithName(nil, domain as CFString).takeRetainedValue()
        var resolved = false
        var dnsError: CFStreamError?

        CFHostStartInfoResolution(host, .addresses, &dnsError)

        guard dnsError?.error == 0 else {
            throw NetworkError.dnsResolutionFailed(domain)
        }

        var addresses: [String] = []
        if let data = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] {
            for addrData in data {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                addrData.withUnsafeBytes { ptr in
                    let sockaddr = ptr.bindMemory(to: sockaddr.self)
                    if let baseAddress = sockaddr.baseAddress {
                        let socklen = socklen_t(addrData.count)
                        getnameinfo(baseAddress, socklen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                let ip = String(cString: hostname)
                if !ip.isEmpty && !addresses.contains(ip) {
                    addresses.append(ip)
                }
            }
        }

        if addresses.isEmpty {
            // Fallback: use Network framework
            let resolved = try await resolveWithNetwork(domain)
            addresses = resolved
        }

        return addresses
    }

    private static func resolveWithNetwork(_ domain: String) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            let resolver = NWConnection(
                host: NWEndpoint.Host(domain),
                port: NWEndpoint.Port(integerLiteral: 80),
                using: .tcp
            )

            var addresses: [String] = []
            resolver.stateUpdateHandler = { state in
                if case .ready = state {
                    if let endpoint = resolver.currentPath?.remoteEndpoint {
                        addresses = [endpoint.debugDescription]
                    }
                    resolver.cancel()
                    continuation.resume(returning: addresses)
                } else if case .failed(let error) = state {
                    resolver.cancel()
                    continuation.resume(throwing: NetworkError.dnsResolutionFailed(domain))
                } else if case .waiting = state {
                    // Still resolving, keep waiting
                }
            }
            resolver.start(queue: DispatchQueue.global())

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                resolver.cancel()
                continuation.resume(returning: addresses)
            }
        }
    }

    // MARK: - Bandwidth Test

    /// Quick bandwidth test by downloading a small file
    static func measureLatency(host: String, port: UInt16) async -> TimeInterval? {
        return try? await ping(host: host, port: port, timeout: 3.0)
    }
}

// MARK: - Errors

enum NetworkError: LocalizedError {
    case pingFailed(Error)
    case pingTimeout
    case pingCancelled
    case dnsResolutionFailed(String)
    case invalidHost

    var errorDescription: String? {
        switch self {
        case .pingFailed(let error):
            return "Ping 失败: \(error.localizedDescription)"
        case .pingTimeout:
            return "Ping 超时"
        case .pingCancelled:
            return "Ping 已取消"
        case .dnsResolutionFailed(let domain):
            return "DNS 解析失败: \(domain)"
        case .invalidHost:
            return "无效的主机地址"
        }
    }
}
