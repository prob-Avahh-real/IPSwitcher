import SwiftUI
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var currentNode: ProxyNode?
    @Published var currentIPInfo: IPInfo?
    @Published var stats = ConnectionStats()
    @Published var isCheckingIP = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var quickNodes: [ProxyNode] = []
    @Published var isConnecting = false

    private let vpnService = VPNService.shared
    private let nodeManager = NodeManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    func setupBindings() {
        vpnService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isConnected = (status == .connected)
                self?.isConnecting = (status == .connecting)
            }
            .store(in: &cancellables)

        vpnService.$currentNode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] node in
                self?.currentNode = node
            }
            .store(in: &cancellables)

        vpnService.$stats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.stats = stats
            }
            .store(in: &cancellables)

        nodeManager.$allNodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nodes in
                let favorites = UserDefaultsManager.shared.favoriteNodeIds
                self?.quickNodes = nodes
                    .filter { favorites.contains($0.id) && $0.id != self?.currentNode?.id }
                    .prefix(5)
                    .map { $0 }
            }
            .store(in: &cancellables)
    }

    func toggleConnection() {
        Task {
            do {
                if isConnected {
                    vpnService.disconnect()
                } else {
                    if let savedId = UserDefaultsManager.shared.lastConnectedNodeId,
                       let node = nodeManager.allNodes.first(where: { $0.id == savedId }) {
                        try await vpnService.connect(to: node)
                    } else {
                        try await vpnService.quickConnect()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func quickConnect(to node: ProxyNode) {
        Task {
            do {
                try await vpnService.switchTo(node: node)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func checkCurrentIP() {
        Task {
            isCheckingIP = true
            defer { isCheckingIP = false }

            do {
                let info = try await IPChecker.shared.checkCurrentIP()
                currentIPInfo = info
            } catch {
                errorMessage = "无法获取 IP 信息: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    func refreshQuickNodes() {
        let favorites = UserDefaultsManager.shared.favoriteNodeIds
        quickNodes = nodeManager.allNodes
            .filter { favorites.contains($0.id) && $0.id != currentNode?.id }
            .prefix(5)
            .map { $0 }
    }
}

// MARK: - Main Dashboard View

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var vpnService: VPNService
    @EnvironmentObject var nodeManager: NodeManager
    @State private var showingIPDetail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionStatusSection
                    currentIPSection
                    quickSwitchSection
                    trafficStatsSection
                }
                .padding()
            }
            .navigationTitle("IP Switcher")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.checkCurrentIP() }) {
                        if viewModel.isCheckingIP {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear {
                viewModel.setupBindings()
                viewModel.checkCurrentIP()
            }
            .alert("错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $showingIPDetail) {
                IPDetailSheet(ipInfo: viewModel.currentIPInfo)
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        VStack(spacing: 16) {
            // Connection Button with Animation
            ZStack {
                // Pulse rings
                if viewModel.isConnected {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.green.opacity(0.3), lineWidth: 2)
                            .frame(width: 180 + CGFloat(i * 30),
                                   height: 180 + CGFloat(i * 30))
                            .scaleEffect(viewModel.isConnected ? 1 : 0.8)
                            .opacity(viewModel.isConnected ? 0.5 : 0)
                            .animation(
                                .easeInOut(duration: 1.5).repeatForever(autoreverses: false).delay(Double(i) * 0.3),
                                value: viewModel.isConnected
                            )
                    }
                }

                Button(action: viewModel.toggleConnection) {
                    VStack(spacing: 8) {
                        Image(systemName: viewModel.isConnected ? "lock.fill" : "lock.open")
                            .font(.system(size: 36))
                            .foregroundColor(.white)

                        if viewModel.isConnecting {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .frame(width: 120, height: 120)
                    .background(
                        Circle()
                            .fill(viewModel.isConnected ? Color.green :
                                     viewModel.isConnecting ? Color.orange : Color.gray.opacity(0.4))
                    )
                    .overlay(
                        Circle()
                            .stroke(viewModel.isConnected ? Color.green.opacity(0.6) : Color.gray.opacity(0.2),
                                    lineWidth: 4)
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(viewModel.isConnected ? 1.05 : 1.0)
                .animation(.spring(response: 0.4), value: viewModel.isConnected)
            }
            .frame(height: 200)

            // Status Text
            VStack(spacing: 4) {
                Text(viewModel.isConnected ? "已连接" : viewModel.isConnecting ? "连接中..." : "未连接")
                    .font(.title2)
                    .fontWeight(.semibold)

                if let node = viewModel.currentNode {
                    HStack(spacing: 4) {
                        Text(node.regionFlag)
                        Text("\(node.city) · \(node.provider)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if let latency = node.latency {
                        Text("延迟: \(Int(latency * 1000))ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Connect/Disconnect Button
            Button(action: viewModel.toggleConnection) {
                Text(viewModel.isConnected ? "断开连接" : viewModel.isConnecting ? "取消" : "连接")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(viewModel.isConnected ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
                    .cornerRadius(10)
            }
            .disabled(viewModel.isConnecting)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10)
    }

    // MARK: - Current IP

    private var currentIPSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                Text("当前 IP 地址")
                    .font(.headline)
                Spacer()
                if viewModel.isCheckingIP {
                    ProgressView()
                }
            }

            if let ipInfo = viewModel.currentIPInfo {
                HStack {
                    Text(ipInfo.flag)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ipInfo.ip)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.medium)
                        Text(ipInfo.locationString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showingIPDetail.toggle() }) {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(10)
            } else {
                HStack {
                    ProgressView()
                    Text("正在获取 IP 信息...")
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10)
    }

    // MARK: - Quick Switch

    private var quickSwitchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.blue)
                Text("快速切换")
                    .font(.headline)
                Spacer()
                if !viewModel.quickNodes.isEmpty {
                    Text("点击切换")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.quickNodes.isEmpty {
                HStack {
                    Image(systemName: "star")
                        .foregroundColor(.yellow)
                    Text("收藏节点后快速切换")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.quickNodes) { node in
                            QuickNodeCard(node: node) {
                                viewModel.quickConnect(to: node)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10)
    }

    // MARK: - Traffic Stats

    private var trafficStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar")
                    .foregroundColor(.blue)
                Text("流量统计")
                    .font(.headline)
                Spacer()
                if viewModel.isConnected {
                    Text(viewModel.stats.durationFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 30) {
                StatItem(
                    icon: "arrow.down.circle",
                    label: "下载",
                    value: viewModel.stats.receivedFormatted,
                    color: .blue
                )
                StatItem(
                    icon: "arrow.up.circle",
                    label: "上传",
                    value: viewModel.stats.sentFormatted,
                    color: .orange
                )
                StatItem(
                    icon: "number",
                    label: "数据包",
                    value: "\(viewModel.stats.packetsProcessed)",
                    color: .green
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10)
    }
}

// MARK: - Supporting Views

struct QuickNodeCard: View {
    let node: ProxyNode
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(node.regionFlag)
                    .font(.largeTitle)
                Text(node.city)
                    .font(.caption)
                    .fontWeight(.medium)
                if let latency = node.latency {
                    Text("\(Int(latency * 1000))ms")
                        .font(.caption2)
                        .foregroundColor(latency < 0.1 ? .green : latency < 0.2 ? .orange : .red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .pressAction {
            withAnimation(.spring(response: 0.2)) { isPressed = true }
        } onRelease: {
            withAnimation(.spring(response: 0.2)) { isPressed = false }
        }
    }
}

struct StatItem: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct IPDetailSheet: View {
    let ipInfo: IPInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let info = ipInfo {
                    Text(info.flag)
                        .font(.system(size: 80))

                    Text(info.ip)
                        .font(.system(.title, design: .monospaced))
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: "国家", value: info.country)
                        DetailRow(label: "地区", value: info.region)
                        DetailRow(label: "城市", value: info.city)
                        DetailRow(label: "ISP", value: info.isp)
                        DetailRow(label: "时区", value: info.timezone)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                } else {
                    Text("无法获取 IP 信息")
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("IP 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Press Action Modifier

struct PressAction: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressAction(onPress: onPress, onRelease: onRelease))
    }
}
