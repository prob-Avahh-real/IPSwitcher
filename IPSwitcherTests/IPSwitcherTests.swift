import XCTest
@testable import IPSwitcher

final class IPSwitcherTests: XCTestCase {
    func testProxyNodeModel() {
        let node = ProxyNode(
            id: "test-id",
            name: "Test Node",
            serverAddress: "192.168.1.1",
            port: 443,
            method: .aes256GCM,
            password: "testpass",
            protocolType: .shadowsocks,
            region: "jp",
            city: "Tokyo",
            provider: "Test",
            bandwidth: 100,
            features: [.social]
        )
        XCTAssertEqual(node.serverAddress, "192.168.1.1")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.region, "jp")
    }

    func testAppConfigDefaults() {
        let config = AppConfig()
        XCTAssertTrue(config.killSwitch)
        XCTAssertTrue(config.dnsLeakProtection)
        XCTAssertFalse(config.ipv6Support)
        XCTAssertFalse(config.autoConnect)
    }

    func testRegionDetector() {
        let region = RegionDetector.detect(from: "tokyo.example.com")
        XCTAssertEqual(region, "jp")
        let region2 = RegionDetector.detect(from: "singapore.server.com")
        XCTAssertEqual(region2, "sg")
        let region3 = RegionDetector.detect(from: "unknown.server.com")
        XCTAssertNil(region3)
    }

    func testConfigValidation() {
        let configService = ConfigService()
        let validNode = ProxyNode(id: "1", name: "Valid", serverAddress: "1.2.3.4", port: 8080, method: .aes256GCM, password: "pass", protocolType: .shadowsocks, region: "us", city: "", provider: "", bandwidth: 0, features: [])
        let invalidNode = ProxyNode(id: "2", name: "Invalid", serverAddress: "", port: 0, method: .aes256GCM, password: "", protocolType: .shadowsocks, region: "", city: "", provider: "", bandwidth: 0, features: [])
        XCTAssertTrue(configService.validateNode(validNode))
        XCTAssertFalse(configService.validateNode(invalidNode))
    }
}
