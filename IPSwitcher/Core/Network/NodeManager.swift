import Foundation
import Network

actor NodeManager: ObservableObject {
    static let shared = NodeManager()

    @MainActor @Published private(set) var allNodes: [ProxyNode] = []
    @MainActor @Published private(set) var activeNode: ProxyNode?
    @MainActor @Published private(set) var isHealthChecking = false

    private var healthCheckTask: Task<Void, Never>?

    deinit {
        healthCheckTask?.cancel()
    }

    // MARK: - Node Management

    @MainActor
    func setNodes(_ nodes: [ProxyNode]) {
        allNodes = nodes
        UserDefaultsManager.shared.saveNodes(nodes)
    }

    @MainActor
    func addNode(_ node: ProxyNode) {
        allNodes.append(node)
        UserDefaultsManager.shared.saveNodes(allNodes)
    }

    @MainActor
    func removeNode(id: String) {
        allNodes.removeAll { $0.id == id }
        UserDefaultsManager.shared.saveNodes(allNodes)
    }

    @MainActor
    func updateNode(_ node: ProxyNode) {
        guard let index = allNodes.firstIndex(where: { $0.id == node.id }) else { return }
        allNodes[index] = node
        UserDefaultsManager.shared.saveNodes(allNodes)
    }

    @MainActor
    func setActiveNode(_ node: ProxyNode?) {
        activeNode = node
    }

    @MainActor
    func nodesByRegion() -> [(region: String, nodes: [ProxyNode])] {
        let grouped = Dictionary(grouping: allNodes) { $0.region }
        return grouped.map { ($0.key, $0.value) }
            .sorted { $0.region < $1.region }
    }

    @MainActor
    func favorites() -> [ProxyNode] {
        let favorites = UserDefaultsManager.shared.favoriteNodeIds
        return allNodes.filter { favorites.contains($0.id) }
    }

    // MARK: - Node Selection

    @MainActor
    func selectNode(strategy: SelectionStrategy) async throws -> ProxyNode {
        let online = allNodes.filter { $0.isOnline }
        guard !online.isEmpty else {
            throw VPNError.nodeUnavailable("所有节点离线")
        }

        switch strategy {
        case .lowestLatency:
            return online
                .sorted { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
                .first!

        case .specificRegion(let region):
            let regionNodes = online.filter { $0.region == region }
            guard let node = regionNodes.first else {
                throw VPNError.nodeUnavailable("区域 \(region) 无可用节点")
            }
            return node

        case .random:
            return online.randomElement()!

        case .byFeature(let feature):
            let featureNodes = online.filter { $0.features.contains(feature) }
            guard let node = featureNodes.first else {
                // Fall back to lowest latency if no feature-specific node
                return try await selectNode(strategy: .lowestLatency)
            }
            return node
        }
    }

    // MARK: - Health Check

    func startHealthCheckLoop() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            await self?.performHealthCheckLoop()
        }
    }

    func stopHealthCheckLoop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    private func performHealthCheckLoop() async {
        while !Task.isCancelled {
            await runHealthCheck()
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
        }
    }

    func runHealthCheck() async {
        await MainActor.run { isHealthChecking = true }

        let nodes = await allNodes
        await withTaskGroup(of: (Int, Bool, TimeInterval).self) { group in
            for (index, node) in nodes.enumerated() {
                group.addTask {
                    let start = CFAbsoluteTimeGetCurrent()
                    let online = await self.pingNode(node)
                    let latency = online ? CFAbsoluteTimeGetCurrent() - start : .infinity
                    return (index, online, latency)
                }
            }

            var updatedNodes = nodes
            for await (index, online, latency) in group {
                updatedNodes[index].isOnline = online
                if online {
                    updatedNodes[index].latancy = latency
                }
            }

            await MainActor.run {
                allNodes = updatedNodes
                isHealthChecking = false
                NotificationCenter.default.post(name: .nodeLatencyDidUpdate, object: nil)
            }
        }
    }

    private func pingNode(_ node: ProxyNode) async -> Bool {
        let host = NWEndpoint.Host(node.serverAddress)
        let port = NWEndpoint.Port(integerLiteral: UInt16(node.port))

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let timeout = 5.0

        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                if state == .ready {
                    connection.cancel()
                    continuation.resume(returning: true)
                } else if state == .failed || state == .cancelled {
                    continuation.resume(returning: false)
                }
            }

            connection.start(queue: DispatchQueue.global())

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Cleanup

    func cancelAll() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }
}

