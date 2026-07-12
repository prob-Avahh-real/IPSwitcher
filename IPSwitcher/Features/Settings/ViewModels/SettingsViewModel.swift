import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var config = AppConfig()
    @Published var dataUsage: UInt64 = 0
    @Published var connectionCount = 0
    @Published var vpnLogs: [String] = []

    private let vpnService = VPNService.shared

    func loadSettings() {
        config = UserDefaultsManager.shared.appConfig
        dataUsage = UserDefaultsManager.shared.totalTrafficBytes
        connectionCount = UserDefaultsManager.shared.connectionHistory.count
    }

    func saveConfig() {
        UserDefaultsManager.shared.appConfig = config
    }

    func toggleKillSwitch() {
        config.killSwitch.toggle()
        saveConfig()
    }

    func toggleDNSProtection() {
        config.dnsLeakProtection.toggle()
        saveConfig()
    }

    func toggleAutoConnect() {
        config.autoConnect.toggle()
        saveConfig()
    }

    func clearData() {
        UserDefaultsManager.shared.clearAllData()
        config = AppConfig()
        dataUsage = 0
    }

    func exportConfig() {
        // Trigger export flow via share sheet
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @EnvironmentObject var vpnService: VPNService
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                // VPN Configuration
                Section("VPN 配置") {
                    Toggle(isOn: Binding(
                        get: { viewModel.config.killSwitch },
                        set: { _ in viewModel.toggleKillSwitch() }
                    )) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Kill Switch")
                                Text("断开 VPN 时阻止所有网络访问")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "switch.2")
                                .foregroundColor(.red)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { viewModel.config.dnsLeakProtection },
                        set: { _ in viewModel.toggleDNSProtection() }
                    )) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("DNS 泄漏保护")
                                Text("防止 DNS 请求绕过 VPN")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.blue)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { viewModel.config.autoConnect },
                        set: { _ in viewModel.toggleAutoConnect() }
                    )) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("自动连接")
                                Text("启动 App 时自动连接 VPN")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bolt")
                                .foregroundColor(.orange)
                        }
                    }

                    Toggle("IPv6 支持", isOn: $viewModel.config.ipv6Support)
                        .onChange(of: viewModel.config.ipv6Support) { _ in
                            viewModel.saveConfig()
                        }
                }

                // Proxy Rules
                Section("分流规则") {
                    NavigationLink(destination: ProxyRulesView()) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("代理规则")
                                Text("管理直连和代理域名")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundColor(.green)
                        }
                    }

                    NavigationLink(destination: BypassSettingsView()) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("绕过设置")
                                Text("配置局域网和私有地址绕过")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundColor(.purple)
                        }
                    }
                }

                // Connection
                Section("连接历史") {
                    let history = UserDefaultsManager.shared.connectionHistory
                    if history.isEmpty {
                        Text("暂无连接记录")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(history.prefix(10)) { record in
                            HStack {
                                Text(RegionFlags.flag(for: record.region))
                                VStack(alignment: .leading) {
                                    Text(record.region.uppercased())
                                        .font(.subheadline)
                                    Text(record.formattedDate)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let duration = record.duration {
                                    Text(formatDuration(duration))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // Data & Privacy
                Section("数据与隐私") {
                    HStack {
                        Label("总流量", systemImage: "arrow.up.arrow.down")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(viewModel.dataUsage), countStyle: .file))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("连接次数", systemImage: "number")
                        Spacer()
                        Text("\(viewModel.connectionCount)")
                            .foregroundColor(.secondary)
                    }
                }

                // Actions
                Section {
                    Button(action: { showingClearConfirmation = true }) {
                        Label("清除所有数据", systemImage: "trash")
                            .foregroundColor(.red)
                    }

                    Button(action: { viewModel.exportConfig() }) {
                        Label("导出配置", systemImage: "square.and.arrow.up")
                    }

                    NavigationLink(destination: AboutView()) {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                viewModel.loadSettings()
            }
            .alert("清除所有数据", isPresented: $showingClearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) { viewModel.clearData() }
            } message: {
                Text("这将清除所有节点、设置和连接记录。此操作不可撤销。")
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        return "\(hours)小时\(minutes % 60)分钟"
    }
}

// MARK: - Proxy Rules View

struct ProxyRulesView: View {
    @State private var directDomains: [String] = []
    @State private var proxyDomains: [String] = []
    @State private var newDomain = ""

    var body: some View {
        List {
            Section("直连域名") {
                ForEach(directDomains, id: \.self) { domain in
                    Text(domain)
                        .font(.system(.subheadline, design: .monospaced))
                }
                .onDelete { directDomains.remove(atOffsets: $0) }

                HStack {
                    TextField("例如: *.apple.com", text: $newDomain)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("添加") {
                        let trimmed = newDomain.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !directDomains.contains(trimmed) {
                            directDomains.append(trimmed)
                            newDomain = ""
                            save()
                        }
                    }
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("代理域名") {
                ForEach(proxyDomains, id: \.self) { domain in
                    Text(domain)
                        .font(.system(.subheadline, design: .monospaced))
                }
                .onDelete { proxyDomains.remove(atOffsets: $0) }
            }

            Section {
                Button("恢复默认", role: .destructive) {
                    directDomains = ProxyRuleSet.defaultDirectDomains
                    proxyDomains = ProxyRuleSet.defaultSocialDomains
                    save()
                }
            }
        }
        .navigationTitle("代理规则")
        .onAppear {
            load()
        }
    }

    private func load() {
        let config = UserDefaultsManager.shared.appConfig
        directDomains = config.proxyDirectDomains
        proxyDomains = config.proxyBypassDomains
    }

    private func save() {
        var config = UserDefaultsManager.shared.appConfig
        config.proxyDirectDomains = directDomains
        config.proxyBypassDomains = proxyDomains
        UserDefaultsManager.shared.appConfig = config
    }
}

// MARK: - Bypass Settings

struct BypassSettingsView: View {
    @State private var bypassRanges: [String] = []

    var body: some View {
        List {
            Section("私有地址绕过") {
                ForEach(bypassRanges, id: \.self) { range in
                    Text(range)
                        .font(.system(.subheadline, design: .monospaced))
                }
            }

            Section {
                Text("以下地址范围将不经过代理，直接连接")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16\n100.64.0.0/10")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("绕过设置")
        .onAppear {
            bypassRanges = ProxyRuleSet.defaultBypassDomains
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("IP Switcher")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("版本 1.0.0")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
            }

            Section("功能") {
                FeatureRow(icon: "globe", title: "全球节点覆盖", subtitle: "日本、美国、新加坡等多地服务器")
                FeatureRow(icon: "lock.shield", title: "流量加密", subtitle: "AES-256-GCM / ChaCha20 加密")
                FeatureRow(icon: "arrow.left.arrow.right", title: "快速切换", subtitle: "秒级节点切换")
                FeatureRow(icon: "magnifyingglass", title: "DNS 泄漏保护", subtitle: "防止 IP 泄露")
            }

            Section("法律信息") {
                NavigationLink("服务条款") {
                    LegalTextView(title: "服务条款", content: termsOfService)
                }
                NavigationLink("隐私政策") {
                    LegalTextView(title: "隐私政策", content: privacyPolicy)
                }
                NavigationLink("开源许可") {
                    LegalTextView(title: "开源许可", content: licenses)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text("Made with ❤️")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .navigationTitle("关于")
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LegalTextView: View {
    let title: String
    let content: String

    var body: some View {
        ScrollView {
            Text(content)
                .font(.subheadline)
                .padding()
        }
        .navigationTitle(title)
    }
}

// MARK: - Legal Content

private let termsOfService = """
    服务条款

1. 服务说明
本应用提供虚拟 IP 切换功能，允许用户通过加密隧道连接到不同地区的服务器。

2. 合法使用
用户承诺遵守所在地法律法规，不将本服务用于任何非法目的。

3. 免责声明
本应用不记录用户流量，不对用户行为负责。

4. 服务变更
我们保留随时修改或终止服务的权利。
"""

private let privacyPolicy = """
    隐私政策

1. 信息收集
本应用不收集任何个人身份信息。
不记录浏览历史、流量内容或 DNS 查询。

2. 数据处理
所有网络流量经过加密传输。
不会存储或分析用户的上网行为。

3. 第三方服务
IP 检测服务仅用于显示当前出口 IP，不会记录或存储。

4. 数据删除
用户可以随时清除 App 内的所有数据。
"""

private let licenses = """
    开源许可

本应用基于以下开源项目：

- Shadowsocks-libev (GPLv3)
- V2Ray (MIT)
- Trojan (GPLv3)
- SwiftNIO (Apache 2.0)
- Alamofire (MIT)

完整许可请查看各项目仓库。
"""
