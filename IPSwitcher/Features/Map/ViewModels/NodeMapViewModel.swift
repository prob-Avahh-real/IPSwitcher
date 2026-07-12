import SwiftUI
import MapKit

@MainActor
final class NodeMapViewModel: ObservableObject {
    @Published var nodes: [ProxyNode] = []
    @Published var selectedNode: ProxyNode?
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 30, longitude: 105),
        span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 50)
    )
    @Published var isConnecting = false
    @Published var showError = false
    @Published var errorMessage: String?

    private let nodeManager = NodeManager.shared
    private let vpnService = VPNService.shared

    /// Map annotations derived from nodes
    var annotations: [NodeAnnotation] {
        nodes.compactMap { node -> NodeAnnotation? in
            guard let coordinate = RegionCoordinates.coordinate(for: node.region) else { return nil }
            return NodeAnnotation(
                node: node,
                coordinate: coordinate,
                isActive: vpnService.currentNode?.id == node.id,
                latency: node.latency
            )
        }
    }

    func loadNodes() {
        nodes = nodeManager.allNodes

        // Center map on active node if connected
        if let activeNode = vpnService.currentNode,
           let coord = RegionCoordinates.coordinate(for: activeNode.region) {
            region.center = coord
            region.span = MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)
        }
    }

    func connectTo(node: ProxyNode) {
        Task {
            do {
                isConnecting = true
                try await vpnService.switchTo(node: node)
                isConnecting = false
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                isConnecting = false
            }
        }
    }

    func selectAnnotation(_ annotation: NodeAnnotation) {
        selectedNode = annotation.node
    }
}

// MARK: - Model

struct NodeAnnotation: Identifiable {
    let node: ProxyNode
    let coordinate: CLLocationCoordinate2D
    let isActive: Bool
    let latency: TimeInterval?

    var id: String { node.id }
}

// MARK: - Map View

struct NodeMapView: View {
    @StateObject private var viewModel = NodeMapViewModel()
    @EnvironmentObject var vpnService: VPNService

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Map
                Map(coordinateRegion: $viewModel.region,
                    annotationItems: viewModel.annotations) { annotation in
                    MapAnnotation(coordinate: annotation.coordinate) {
                        NodeMapMarker(annotation: annotation)
                            .onTapGesture {
                                viewModel.selectAnnotation(annotation)
                            }
                    }
                }
                .ignoresSafeArea(edges: .bottom)

                // Bottom Sheet
                if let node = viewModel.selectedNode {
                    VStack(spacing: 0) {
                        // Handle
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 40, height: 5)
                            .padding(.top, 8)

                        VStack(spacing: 12) {
                            HStack {
                                Text(node.regionFlag)
                                    .font(.system(size: 48))
                                VStack(alignment: .leading) {
                                    Text(node.name)
                                        .font(.headline)
                                    Text("\(node.city), \(node.provider)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }

                            HStack(spacing: 20) {
                                MapStatItem(title: "延迟", value: node.displayLatency)
                                MapStatItem(title: "协议", value: node.protocolType.displayName)
                                MapStatItem(title: "带宽", value: "\(node.bandwidth)Mbps")
                            }

                            Button(action: { viewModel.connectTo(node: node) }) {
                                HStack {
                                    Image(systemName: "network")
                                    Text(vpnService.currentNode?.id == node.id ? "切换至该节点" : "连接该节点")
                                }
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                        }
                        .padding()
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.15), radius: 20, y: -5)
                    )
                    .transition(.move(edge: .bottom))
                    .animation(.spring(response: 0.4), value: viewModel.selectedNode?.id)
                }
            }
            .navigationTitle("全球节点")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isConnecting {
                        ProgressView()
                    }
                }
            }
            .onAppear {
                viewModel.loadNodes()
            }
            .alert("错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

// MARK: - Map Marker

struct NodeMapMarker: View {
    let annotation: NodeAnnotation

    var body: some View {
        VStack(spacing: 2) {
            // Latency indicator
            if let latency = annotation.latency {
                Text("\(Int(latency * 1000))ms")
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(.systemBackground))
                    .cornerRadius(4)
                    .shadow(radius: 1)
            }

            // Marker
            ZStack {
                if annotation.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                        )
                        .shadow(radius: 4)
                }

                Text(annotation.node.regionFlag)
                    .font(.system(size: annotation.isActive ? 28 : 24))
            }
        }
    }
}

// MARK: - Map Stat Item

struct MapStatItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Region Coordinates

enum RegionCoordinates {
    static func coordinate(for region: String) -> CLLocationCoordinate2D? {
        switch region.lowercased() {
        case "jp", "japan", "tyo", "tokyo":
            return CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        case "hk", "hkg", "hongkong", "hong_kong":
            return CLLocationCoordinate2D(latitude: 22.3193, longitude: 114.1694)
        case "sg", "sgp", "singapore":
            return CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
        case "kr", "korea", "sel", "seoul":
            return CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        case "tw", "tpe", "taiwan", "taipei":
            return CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        case "us", "usa", "lax", "los_angeles", "la":
            return CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        case "us-east", "nyc", "new_york":
            return CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        case "us-central", "dfw", "dallas":
            return CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)
        case "gb", "uk", "lhr", "london":
            return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        case "de", "fra", "germany", "frankfurt":
            return CLLocationCoordinate2D(latitude: 50.1109, longitude: 8.6821)
        case "au", "syd", "australia", "sydney":
            return CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        case "ca", "yvr", "canada", "vancouver":
            return CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        case "nl", "ams", "netherlands", "amsterdam":
            return CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.9041)
        case "fr", "cdg", "france", "paris":
            return CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        case "in", "bom", "india", "mumbai":
            return CLLocationCoordinate2D(latitude: 19.0760, longitude: 72.8777)
        default:
            return nil
        }
    }
}
