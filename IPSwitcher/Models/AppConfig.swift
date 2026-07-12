import Foundation

/// Subscription configuration for importing node lists
struct SubscriptionConfig: Codable, Identifiable {
    var id: String { url.absoluteString }
    let url: URL
    var name: String
    var isAutoUpdate: Bool = true
    var lastUpdated: Date?
    var updateInterval: TimeInterval = 86400 // 24 hours
}

/// Full app configuration
struct AppConfig: Codable {
    var autoConnect: Bool = false
    var launchOnStart: Bool = false
    var killSwitch: Bool = true
    var dnsLeakProtection: Bool = true
    var ipv6Support: Bool = false
    var proxyRules: [ProxyRule] = []
    var selectedNodeId: String?
    var subscription: SubscriptionConfig?
    var theme: ThemeMode = .system
    var proxyBypassDomains: [String] = ProxyRuleSet.defaultBypassDomains
    var proxyDirectDomains: [String] = ProxyRuleSet.defaultDirectDomains

    enum ThemeMode: String, Codable, CaseIterable {
        case light = "light"
        case dark = "dark"
        case system = "system"
    }
}

/// Default proxy rule sets
enum ProxyRuleSet {
    static let defaultBypassDomains = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
    ]

    static let defaultDirectDomains = [
        "*.apple.com",
        "*.icloud.com",
        "*.icloud-content.com",
        "itunes.apple.com",
        "localhost",
        "*.local",
    ]

    static let defaultSocialDomains = [
        "*.facebook.com",
        "*.instagram.com",
        "*.twitter.com",
        "*.x.com",
        "*.tiktok.com",
        "*.tiktokv.com",
        "*.snapchat.com",
        "*.telegram.org",
        "*.whatsapp.net",
        "*.discord.com",
        "*.reddit.com",
        "*.linkedin.com",
        "*.wechat.com",
        "*.weixin.qq.com",
    ]
}
