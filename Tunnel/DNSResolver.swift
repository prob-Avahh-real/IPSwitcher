import Foundation
import Network

/// DNS resolver for the tunnel - handles domain resolution within the tunnel
final class DNSResolver {
    static let shared = DNSResolver()

    private let dnsServers: [String]
    private let cache = NSCache<NSString, CacheEntry>()
    private let queue = DispatchQueue(label: "com.ipswitcher.dns", attributes: .concurrent)

    init(dnsServers: [String] = ["1.1.1.1", "8.8.8.8"]) {
        self.dnsServers = dnsServers
        cache.countLimit = 1000
    }

    // MARK: - Resolution

    /// Resolve a domain to an IP address using the configured DNS servers
    /// Returns nil if resolution fails
    func resolve(_ domain: String) async -> String? {
        // Check cache first
        if let cached = cachedResult(for: domain) {
            return cached
        }

        // Skip resolution for IP addresses
        if NetworkUtils.isValidIPAddress(domain) {
            return domain
        }

        // Try DNS resolution
        let result = try? await NetworkUtils.resolveDomain(domain)
        let ip = result?.first

        // Cache the result
        if let ip = ip {
            cacheResult(ip, for: domain, ttl: 300)
        }

        return ip
    }

    /// Resolve multiple domains in parallel
    func resolveBatch(_ domains: [String]) async -> [String: String] {
        var results: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for domain in domains {
                group.addTask {
                    let ip = await self.resolve(domain)
                    return (domain, ip)
                }
            }

            for await (domain, ip) in group {
                if let ip = ip {
                    results[domain] = ip
                }
            }
        }

        return results
    }

    /// Clear the DNS cache
    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Cache

    private func cachedResult(for domain: String) -> String? {
        queue.sync {
            guard let entry = cache.object(forKey: domain as NSString) else { return nil }
            guard entry.expiresAt > Date() else {
                cache.removeObject(forKey: domain as NSString)
                return nil
            }
            return entry.ip
        }
    }

    private func cacheResult(_ ip: String, for domain: String, ttl: TimeInterval) {
        queue.async(flags: .barrier) {
            let entry = CacheEntry(ip: ip, expiresAt: Date().addingTimeInterval(ttl))
            self.cache.setObject(entry, forKey: domain as NSString)
        }
    }

    // MARK: - Prefetching

    /// Prefetch DNS for common social media domains
    func prefetchSocialDomains() async {
        let socialDomains = [
            "facebook.com", "instagram.com", "twitter.com", "x.com",
            "tiktok.com", "tiktokv.com", "snapchat.com",
            "telegram.org", "whatsapp.net", "discord.com",
            "reddit.com", "linkedin.com", "wechat.com",
        ]

        let results = await resolveBatch(socialDomains)
        let resolved = results.compactMap { $0.value }.joined(separator: ", ")
        os_log("[DNSResolver] Prefetched %d domains", log: .default, type: .debug, socialDomains.count)
    }
}

// MARK: - Cache Entry

private class CacheEntry {
    let ip: String
    let expiresAt: Date

    init(ip: String, expiresAt: Date) {
        self.ip = ip
        self.expiresAt = expiresAt
    }
}
