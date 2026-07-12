import SwiftUI

@MainActor
final class NodeListViewModel: ObservableObject {
    @Published var nodes: [ProxyNode] = []
    @Published var searchText = ""
    @Published var selectedRegion: String?
    @Published var sortOrder: SortOrder = .latency
    @Published var isRefreshing = false
    @Published var showError = false
    @Published var errorMessage: String?

    private let nodeManager = NodeManager.shared
    private let vpnService = VPNService.shared

    var regions: [String] {
        Array(Set(nodes.map { $0.region })).sorted()
    }

    var filteredNodes: [ProxyNode] {
        var result = nodes

        // Filter by region
        if let region = selectedRegion {
            result = result.filter { $0.region == region }
        }

        // Filter by search
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.city.localizedCaseInsensitiveContains(searchText) ||
                $0.provider.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .latency:
            result.sort { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
        case .region:
            result.sort { $0.region < $1.region }
        case .name:
            result.sort { $0.name < $1.name }
        }

        return result
    }

    var groupedByRegion: [(region: String, nodes: [ProxyNode])] {
        let filtered = filteredNodes
        let grouped = Dictionary(grouping: filtered) { $0.region }
        return grouped.map { ($0.key, $0.value) }
            .sorted { $0.region < $1.region }
    }

    enum SortOrder: String, CaseIterable {
        case latency = "延迟"
        case region = "区域"
        case name = "名称"
    }

    func loadNodes() {
        nodes = nodeManager.allNodes
    }

    func refreshNodes() {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }

            await nodeManager.runHealthCheck()
            nodes = nodeManager.allNodes
        }
    }

    func connectTo(node: ProxyNode) {
        Task {
            do {
                try await vpnService.switchTo(node: node)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func toggleFavorite(nodeId: String) {
        UserDefaultsManager.shared.toggleFavorite(nodeId: nodeId)
        // Trigger UI update
        objectWillChange.send()
    }

    func isFavorite(nodeId: String) -> Bool {
        UserDefaultsManager.shared.isFavorite(nodeId: nodeId)
    }

    var favoriteNodes: [ProxyNode] {
        let favorites = UserDefaultsManager.shared.favoriteNodeIds
        return nodes.filter { favorites.contains($0.id) }
    }
}

// MARK: - Node List View

struct NodeListView: View {
    @StateObject private var viewModel = NodeListViewModel()
    @EnvironmentObject var nodeManager: NodeManager
    @EnvironmentObject var vpnService: VPNService
    @State private var showingFavorites = false
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Region Filter
                regionFilterBar

                // Node List
                if viewModel.filteredNodes.isEmpty {
                    emptyState
                } else {
                    List {
                        if showingFavorites && !viewModel.favoriteNodes.isEmpty {
                            favoritesSection
                        }
                        nodesSection
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        viewModel.refreshNodes()
                    }
                }
            }
            .navigationTitle("节点列表")
            .searchable(text: $viewModel.searchText, prompt: "搜索节点名称/城市")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingFavorites.toggle() }) {
                        Image(systemName: showingFavorites ? "star.fill" : "star")
                            .foregroundColor(.yellow)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("排序", selection: $viewModel.sortOrder) {
                            ForEach(NodeListViewModel.SortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }

                        Button(action: { viewModel.refreshNodes() }) {
                            Label("刷新延迟", systemImage: "arrow.clockwise")
                        }

                        Button(action: { showingImport = true }) {
                            Label("导入订阅", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                viewModel.loadNodes()
            }
            .onReceive(NotificationCenter.default.publisher(for: .nodeLatencyDidUpdate)) { _ in
                viewModel.loadNodes()
            }
            .alert("错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $showingImport) {
                SubscriptionImportView()
            }
        }
    }

    private var regionFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All
                Button(action: { viewModel.selectedRegion = nil }) {
                    Text("全部")
                        .font(.caption)
                        .fontWeight(viewModel.selectedRegion == nil ? .semibold : .regular)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.selectedRegion == nil ? Color.blue : Color(.systemGray6))
                        .foregroundColor(viewModel.selectedRegion == nil ? .white : .primary)
                        .cornerRadius(16)
                }

                ForEach(viewModel.regions, id: \.self) { region in
                    Button(action: {
                        viewModel.selectedRegion = viewModel.selectedRegion == region ? nil : region
                    }) {
                        HStack(spacing: 4) {
                            Text(RegionFlags.flag(for: region))
                            Text(region.uppercased())
                                .font(.caption)
                        }
                        .fontWeight(viewModel.selectedRegion == region ? .semibold : .regular)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.selectedRegion == region ? Color.blue : Color(.systemGray6))
                        .foregroundColor(viewModel.selectedRegion == region ? .white : .primary)
                        .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe.desk")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("没有找到节点")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("尝试调整筛选条件或导入节点订阅")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(action: { showingImport = true }) {
                Label("导入订阅", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    private var favoritesSection: some View {
        Section("⭐ 收藏节点") {
            ForEach(viewModel.favoriteNodes) { node in
                NodeRowView(
                    node: node,
                    isActive: vpnService.currentNode?.id == node.id,
                    isFavorite: true
                ) {
                    viewModel.connectTo(node: node)
                } onToggleFavorite: {
                    viewModel.toggleFavorite(nodeId: node.id)
                }
            }
        }
    }

    private var nodesSection: some View {
        ForEach(viewModel.groupedByRegion, id: \.region) { region, nodes in
            Section {
                ForEach(nodes) { node in
                    NodeRowView(
                        node: node,
                        isActive: vpnService.currentNode?.id == node.id,
                        isFavorite: viewModel.isFavorite(nodeId: node.id)
                    ) {
                        viewModel.connectTo(node: node)
                    } onToggleFavorite: {
                        viewModel.toggleFavorite(nodeId: node.id)
                    }
                }
            } header: {
                HStack {
                    Text(RegionFlags.flag(for: region))
                    Text(region.uppercased())
                }
                .font(.headline)
            }
        }
    }
}

// MARK: - Node Row View

struct NodeRowView: View {
    let node: ProxyNode
    let isActive: Bool
    let isFavorite: Bool
    let onConnect: () -> Void
    let onToggleFavorite: () -> Void

    @State private var showingDetail = false

    var body: some View {
        Button(action: { showingDetail = true }) {
            HStack(spacing: 12) {
                // Region Flag
                Text(node.regionFlag)
                    .font(.title2)

                // Node Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(node.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        if isActive {
                            ActiveBadge()
                        }
                    }

                    HStack(spacing: 4) {
                        Text(node.city)
                        if !node.provider.isEmpty {
                            Text("·")
                            Text(node.provider)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    // Features
                    HStack(spacing: 4) {
                        ForEach(node.features.prefix(3), id: \.self) { feature in
                            Text(feature.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }

                Spacer()

                // Latency & Status
                VStack(alignment: .trailing, spacing: 4) {
                    // Status indicator
                    Circle()
                        .fill(node.isOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    // Latency
                    if let latency = node.latency {
                        Text(node.displayLatency)
                            .font(.caption)
                            .foregroundColor(latencyColor(latency))
                    } else {
                        Text("---")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Load
                    if node.load > 0 {
                        Text("\(Int(node.load * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onConnect) {
                Label(isActive ? "切换至此节点" : "连接此节点", systemImage: "network")
            }

            Button(action: onToggleFavorite) {
                Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.slash" : "star")
            }

            Divider()

            Button(action: { showingDetail = true }) {
                Label("详情", systemImage: "info.circle")
            }
        }
        .swipeActions(edge: .leading) {
            Button(action: onConnect) {
                Label("连接", systemImage: "network")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "取消收藏" : "收藏", systemImage: "star")
            }
            .tint(.yellow)
        }
        .sheet(isPresented: $showingDetail) {
            NodeDetailView(node: node, isFavorite: isFavorite, onToggleFavorite: onToggleFavorite)
        }
    }

    private func latencyColor(_ latency: TimeInterval) -> Color {
        if latency < 0.1 { return .green }
        if latency < 0.2 { return .orange }
        return .red
    }
}

struct ActiveBadge: View {
    var body: some View {
        Text("已连接")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green)
            .cornerRadius(4)
    }
}

// MARK: - Node Detail View

struct NodeDetailView: View {
    let node: ProxyNode
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vpnService: VPNService

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Flag & Name
                VStack(spacing: 8) {
                    Text(node.regionFlag)
                        .font(.system(size: 80))

                    Text(node.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 8) {
                        Text(node.city)
                        Text("·")
                        Text(node.provider)
                    }
                    .foregroundColor(.secondary)
                }

                // Details
                VStack(spacing: 16) {
                    DetailCard(title: "服务器", value: "\(node.serverAddress):\(node.port)")
                    DetailCard(title: "协议", value: node.protocolType.displayName)
                    DetailCard(title: "加密", value: node.method.rawValue)
                    DetailCard(title: "带宽", value: "\(node.bandwidth) Mbps")

                    HStack {
                        DetailCard(title: "延迟", value: node.displayLatency)
                        DetailCard(title: "负载", value: node.load > 0 ? "\(Int(node.load * 100))%" : "---")
                    }
                }

                // Connect Button
                Button(action: {
                    Task { try? await vpnService.switchTo(node: node) }
                    dismiss()
                }) {
                    Text(vpnService.currentNode?.id == node.id ? "切换至此节点" : "连接此节点")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("节点详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
    }
}

struct DetailCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Subscription Import View

struct SubscriptionImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptionURL = ""
    @State private var isImporting = false
    @State private var importedCount = 0
    @State private var showResult = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Info
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("导入节点订阅")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("支持 Shadowsocks / VLESS / Clash 等订阅格式")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // URL Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("订阅地址")
                        .font(.headline)

                    TextField("https://example.com/sub", text: $subscriptionURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                // Import Button
                Button(action: importSubscription) {
                    if isImporting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("导入节点")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(subscriptionURL.isEmpty ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .disabled(subscriptionURL.isEmpty || isImporting)

                // Result
                if showResult {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("成功导入 \(importedCount) 个节点")
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("导入订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("导入失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func importSubscription() {
        guard let url = URL(string: subscriptionURL) else {
            errorMessage = "无效的 URL"
            showError = true
            return
        }

        isImporting = true
        Task {
            do {
                let nodes = try await ConfigService.shared.importFromSubscription(url: url)
                await NodeManager.shared.setNodes(nodes)
                importedCount = nodes.count
                showResult = true
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isImporting = false
        }
    }
}
