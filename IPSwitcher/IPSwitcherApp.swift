import SwiftUI

@main
struct IPSwitcherApp: App {
    @StateObject private var appCoordinator = AppCoordinator.shared
    @StateObject private var vpnService = VPNService.shared
    @StateObject private var nodeManager = NodeManager.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                if appCoordinator.isOnboarding {
                    OnboardingView()
                } else {
                    MainTabView()
                        .environmentObject(appCoordinator)
                        .environmentObject(vpnService)
                        .environmentObject(nodeManager)
                }
            }
            .onAppear {
                appCoordinator.checkFirstLaunch()
                setupAppearance()
            }
        }
    }

    private func setupAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var vpnService: VPNService
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("仪表盘", systemImage: "gauge.medium")
                }
                .tag(0)

            NodeListView()
                .tabItem {
                    Label("节点", systemImage: "globe")
                }
                .tag(1)

            NodeMapView()
                .tabItem {
                    Label("地图", systemImage: "map")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(3)
        }
        .tint(.blue)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var currentPage = 0

    private let pages: [(title: String, description: String, image: String)] = [
        ("虚拟 IP 切换器",
         "一键切换网络身份，在社交平台显示不同地区的 IP 地址",
         "network"),
        ("全球节点覆盖",
         "日本、美国、新加坡、香港等多地服务器，低延迟高速连接",
         "globe"),
        ("隐私保护",
         "加密所有网络流量，防止 IP 泄露和 DNS 泄漏",
         "lock.shield"),
        ("快速切换",
         "收藏常用节点，秒级切换，随时改变你的网络位置",
         "arrow.left.arrow.right"),
    ]

    var body: some View {
        VStack {
            // Skip button
            HStack {
                Spacer()
                Button("跳过") {
                    withAnimation {
                        coordinator.completeOnboarding()
                    }
                }
                .padding()
            }

            // Page content
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    VStack(spacing: 30) {
                        Image(systemName: pages[index].image)
                            .font(.system(size: 80))
                            .foregroundStyle(.blue)
                            .symbolEffect(.bounce, options: .repeat(1))

                        Text(pages[index].title)
                            .font(.largeTitle)
                            .bold()

                        Text(pages[index].description)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // Get Started button
            if currentPage == pages.count - 1 {
                Button(action: {
                    withAnimation {
                        coordinator.completeOnboarding()
                    }
                }) {
                    Text("开始使用")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Error Alert Modifier

extension View {
    func errorAlert(error: Binding<Error?>) -> some View {
        self.alert(isPresented: .constant(error.wrappedValue != nil)) {
            Alert(
                title: Text("错误"),
                message: Text(error.wrappedValue?.localizedDescription ?? ""),
                dismissButton: .default(Text("确定")) {
                    error.wrappedValue = nil
                }
            )
        }
    }
}
