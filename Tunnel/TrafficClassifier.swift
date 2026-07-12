import Foundation

/// Classifies network traffic based on rules
final class TrafficClassifier {
    // MARK: - Rule Sets

    private var bypassRanges: [ClosedRange<UInt32>] = []
    private var directDomains: [String] = []
    private var proxyDomains: [String] = []
    private var customRules: [ProxyRule] = []

    private let defaultBypassRanges: [ClosedRange<UInt32>] = [
        ipRange(from: "10.0.0.0", mask: "255.0.0.0"),
        ipRange(from: "172.16.0.0", mask: "255.240.0.0"),
        ipRange(from: "192.168.0.0", mask: "255.255.0.0"),
        ipRange(from: "100.64.0.0", mask: "255.192.0.0"),
        ipRange(from: "127.0.0.0", mask: "255.0.0.0"),
    ]

    init() {
        bypassRanges = defaultBypassRanges
        directDomains = ProxyRuleSet.defaultDirectDomains
    }

    // MARK: - Configuration

    func updateRules(rules: [ProxyRule]) {
        customRules = rules
    }

    func setDirectDomains(_ domains: [String]) {
        directDomains = domains
    }

    func setProxyDomains(_ domains: [String]) {
        proxyDomains = domains
    }

    // MARK: - Classification

    enum Action {
        case proxy
        case direct
        case drop
    }

    /// Classify a packet by its destination
    func classify(destinationIP: String, destinationPort: UInt16, domain: String? = nil) -> Action {
        // 1. Check custom rules first
        for rule in customRules {
            switch rule.type {
            case .domain:
                if let domain = domain, matchDomain(domain, pattern: rule.value) {
                    return action(from: rule.action)
                }
            case .ipCIDR:
                if matchCIDR(destinationIP, cidr: rule.value) {
                    return action(from: rule.action)
                }
            case .appBundle:
                // App bundle matching is handled at a higher level
                continue
            }
        }

        // 2. Check direct domains
        if let domain = domain {
            for pattern in directDomains {
                if matchDomain(domain, pattern: pattern) {
                    return .direct
                }
            }
            for pattern in proxyDomains {
                if matchDomain(domain, pattern: pattern) {
                    return .proxy
                }
            }
        }

        // 3. Check bypass ranges
        if let ipInt = ipToInt(destinationIP) {
            for range in bypassRanges {
                if range.contains(ipInt) {
                    return .direct
                }
            }
        }

        // 4. Default: proxy everything
        return .proxy
    }

    // MARK: - Matching Helpers

    private func matchDomain(_ domain: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return domain.hasSuffix(suffix) || domain == suffix
        }
        return domain == pattern
    }

    private func matchCIDR(_ ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefixLength = Int(parts[1]),
              let ipInt = ipToInt(ip),
              let networkInt = ipToInt(String(parts[0]))
        else { return false }

        let mask: UInt32
        if prefixLength == 0 {
            mask = 0
        } else {
            mask = ~((1 << (32 - prefixLength)) - 1)
        }

        return (ipInt & mask) == (networkInt & mask)
    }

    private func action(from ruleAction: ProxyRule.RuleAction) -> Action {
        switch ruleAction {
        case .proxy: return .proxy
        case .direct: return .direct
        case .drop: return .drop
        }
    }

    // MARK: - IP Utilities

    private func ipToInt(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    private func ipRange(from ip: String, mask: String) -> ClosedRange<UInt32> {
        guard let ipInt = ipToInt(ip), let maskInt = ipToInt(mask) else {
            return 0...0
        }
        let network = ipInt & maskInt
        let broadcast = network | ~maskInt
        return network...broadcast
    }
}
