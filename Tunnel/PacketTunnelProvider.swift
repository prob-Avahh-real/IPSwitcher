import Foundation
import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Properties

    private var adapter: ProxyProtocolAdapter?
    private var proxyConnection: NWConnection?
    private var config: TunnelConfiguration?
    private let trafficClassifier = TrafficClassifier()
    private var isRunning = false

    // Statistics
    private var bytesReceived: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var packetsProcessed: UInt64 = 0
    private var connectedAt: Date?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. Parse configuration from provider options
        let tunnelConfig: TunnelConfiguration
        do {
            tunnelConfig = try TunnelConfiguration(from: options)
            self.config = tunnelConfig
        } catch {
            completionHandler(error)
            return
        }

        // 2. Create the protocol adapter
        let protocolAdapter = ProxyAdapterFactory.createAdapter(
            for: tunnelConfig.protocolType,
            password: tunnelConfig.password,
            method: tunnelConfig.method
        )
        self.adapter = protocolAdapter

        // 3. Configure tunnel network settings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelConfig.serverAddress)
        settings.mtu = NSNumber(value: tunnelConfig.mtu)

        // 4. Configure DNS
        let dnsSettings = NEDNSSettings(servers: tunnelConfig.dnsServers)
        settings.dnsSettings = dnsSettings

        // 5. Configure IPv4 routing — all traffic via tunnel
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        // 6. Configure IPv6 if needed
        let ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6Settings

        // 7. Apply settings
        apply(settings) { [weak self] error in
            guard let self = self else {
                completionHandler(NSError(domain: "com.ipswitcher.tunnel", code: -1))
                return
            }

            if let error = error {
                self.log("Failed to apply tunnel settings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            // 8. Connect to proxy server
            Task {
                do {
                    try await self.connectToProxyServer(config: tunnelConfig, adapter: protocolAdapter)
                    self.isRunning = true
                    self.connectedAt = Date()

                    // 9. Start reading packets from the virtual interface
                    self.startPacketReading()

                    self.log("Tunnel started successfully")
                    completionHandler(nil)
                } catch {
                    self.log("Failed to connect to proxy: \(error.localizedDescription)")
                    completionHandler(error)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        self.log("Tunnel stopping, reason: \(reason)")

        isRunning = false
        proxyConnection?.cancel()
        proxyConnection = nil
        adapter = nil

        // Update stats
        let duration = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        self.log("Session stats - sent: \(bytesSent), received: \(bytesReceived), duration: \(duration)s")

        connectedAt = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Handle IPC messages from the main app
        Task {
            do {
                let message = try JSONDecoder().decode(TunnelProviderMessage.self, from: messageData)
                let response = try await handleMessage(message)
                completionHandler?(response)
            } catch {
                self.log("Failed to handle app message: \(error.localizedDescription)")
                completionHandler?(nil)
            }
        }
    }

    // MARK: - Proxy Connection

    private func connectToProxyServer(config: TunnelConfiguration, adapter: ProxyProtocolAdapter) async throws {
        // 1. Establish TCP connection to the proxy server
        self.log("Connecting to \(config.serverAddress):\(config.port) via \(config.protocolType.displayName)")

        let connection = try await adapter.connect(to: config.serverAddress, port: config.port)
        self.proxyConnection = connection

        // 2. Start connection handler
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log("Proxy connection failed: \(error.localizedDescription)")
                self?.handleConnectionFailure(error)
            case .cancelled:
                self?.log("Proxy connection cancelled")
            case .ready:
                self?.log("Proxy connection ready")
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global())

        // 3. Wait for connection to be ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSThreadWillExit,
                object: nil,
                queue: nil
            ) { _ in
                // Timeout fallback
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    observer.map { NotificationCenter.default.removeObserver($0) }
                    continuation.resume()
                case .failed(let error):
                    observer.map { NotificationCenter.default.removeObserver($0) }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }

        // 4. Perform protocol handshake
        try await adapter.handshake(connection: connection)
        self.log("Handshake complete for \(config.protocolType.displayName)")
    }

    // MARK: - Packet Reading Loop

    private func startPacketReading() {
        guard isRunning else { return }

        // Read packets from the virtual interface
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            for (index, packet) in packets.enumerated() {
                let proto = protocols[index]
                self.handleOutgoingPacket(packet, protocolFamily: proto)
            }

            // Continue reading
            self.startPacketReading()
        }
    }

    private func handleOutgoingPacket(_ packet: Data, protocolFamily: NSNumber) {
        guard let adapter = adapter, let connection = proxyConnection else { return }

        packetsProcessed += 1

        // Parse destination from IP header
        let (destIP, destPort, domain) = parsePacketDestination(packet, family: protocolFamily)

        // Classify the traffic
        let action = trafficClassifier.classify(
            destinationIP: destIP ?? "",
            destinationPort: destPort ?? 0,
            domain: domain
        )

        switch action {
        case .proxy:
            // Encapsulate and send through the proxy
            let encapsulated = adapter.encapsulate(packet)
            bytesSent += UInt64(encapsulated.count)

            connection.send(content: encapsulated, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.log("Send error: \(error.localizedDescription)")
                }
            })

        case .direct:
            // Write directly back to the virtual interface (bypass proxy)
            packetFlow.writePackets([packet], withProtocols: [protocolFamily])

        case .drop:
            // Silently drop the packet
            break
        }

        // Check for incoming data from the proxy
        receiveFromProxy()
    }

    private func receiveFromProxy() {
        guard let connection = proxyConnection, let adapter = adapter else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.log("Receive error: \(error.localizedDescription)")
                return
            }

            if let data = data {
                // Decapsulate the response
                let decapsulated = adapter.decapsulate(data)
                self.bytesReceived += UInt64(decapsulated.count)

                // Write back to the virtual interface (protocol family AF_INET)
                self.packetFlow.writePackets([decapsulated], withProtocols: [AF_INET as NSNumber])
            }

            if isComplete {
                self.log("Proxy connection closed by server")
                self.disconnectAndReconnect()
            }
        }
    }

    // MARK: - Helpers

    private func parsePacketDestination(_ packet: Data, family: NSNumber) -> (destIP: String?, destPort: UInt16?, domain: String?) {
        let protocolFamily = family.int32Value

        if protocolFamily == AF_INET {
            // Parse IPv4 header
            guard packet.count >= 20 else { return (nil, nil, nil) }

            let header = Array(packet)

            // Source IP (bytes 12-15)
            // Dest IP (bytes 16-19)
            let destIP = "\(header[16]).\(header[17]).\(header[18]).\(header[19])"

            // Header length (lower nibble of byte 0) * 4
            let headerLength = Int((header[0] & 0x0F)) * 4

            // Protocol (byte 9)
            let protocolNum = header[9]

            // Parse destination port based on protocol
            let portOffset = headerLength
            if packet.count >= portOffset + 2 {
                let destPort = (UInt16(header[portOffset]) << 8) | UInt16(header[portOffset + 1])

                // Try to extract SNI from TLS handshake (for domain matching)
                var domain: String?
                if destPort == 443 || destPort == 8443 {
                    domain = extractSNI(from: packet, ipHeaderLength: headerLength)
                }

                return (destIP, destPort, domain)
            }

            return (destIP, nil, nil)

        } else if protocolFamily == AF_INET6 {
            // Parse IPv6 header
            guard packet.count >= 40 else { return (nil, nil, nil) }

            let header = Array(packet)
            let destIP = (0..<8).map { i -> String in
                let offset = 24 + i * 2
                return String(format: "%02x%02x", header[offset], header[offset + 1])
            }.joined(separator: ":")

            // Next header (byte 6 in IPv6)
            let nextHeader = header[6]

            // Destination port
            if packet.count >= 42 {
                let destPort = (UInt16(header[40]) << 8) | UInt16(header[41])
                return (destIP, destPort, nil)
            }

            return (destIP, nil, nil)
        }

        return (nil, nil, nil)
    }

    /// Extract Server Name Indication from TLS ClientHello
    private func extractSNI(from packet: Data, ipHeaderLength: Int) -> String? {
        // TLS ClientHello starts after TCP header
        // TCP header is typically 20 bytes, but can have options
        // We look for the TLS record after the TCP header

        guard packet.count > ipHeaderLength + 20 else { return nil }

        let tcpHeaderLength = Int((packet[ipHeaderLength + 12] >> 4) & 0x0F) * 4
        let tlsOffset = ipHeaderLength + tcpHeaderLength

        guard packet.count > tlsOffset + 5 else { return nil }

        // Check for TLS record type 0x16 (Handshake)
        guard packet[tlsOffset] == 0x16 else { return nil }

        // Parse TLS record to find SNI extension
        // This is a simplified parser - a production implementation
        // would fully parse the TLS ClientHello
        var offset = tlsOffset + 5 // TLS record header

        // Handshake type: ClientHello (0x01)
        guard packet.count > offset + 1, packet[offset] == 0x01 else { return nil }

        offset += 43 // Skip handshake header + version + random

        // Skip session ID
        guard packet.count > offset else { return nil }
        let sessionIDLength = Int(packet[offset])
        offset += 1 + sessionIDLength

        // Skip cipher suites
        guard packet.count > offset + 1 else { return nil }
        let cipherSuiteLength = (Int(packet[offset]) << 8) | Int(packet[offset + 1])
        offset += 2 + cipherSuiteLength

        // Skip compression methods
        guard packet.count > offset else { return nil }
        let compressionLength = Int(packet[offset]) + 1
        offset += compressionLength

        // Extensions
        guard packet.count > offset + 1 else { return nil }
        let extensionsLength = (Int(packet[offset]) << 8) | Int(packet[offset + 1])
        offset += 2

        let extensionsEnd = offset + extensionsLength
        while offset + 4 <= extensionsEnd, offset + 4 <= packet.count {
            let extensionType = (Int(packet[offset]) << 8) | Int(packet[offset + 1])
            let extensionLength = (Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])
            offset += 4

            if extensionType == 0x0000 { // SNI
                guard packet.count >= offset + 5 else { return nil }
                // SNI list length (2 bytes) + entry type (1 byte) + name length (2 bytes)
                let nameLength = (Int(packet[offset + 3]) << 8) | Int(packet[offset + 4])
                guard packet.count >= offset + 5 + nameLength else { return nil }
                let nameData = packet[offset + 5 ..< offset + 5 + nameLength]
                return String(data: nameData, encoding: .utf8)
            }

            offset += extensionLength
        }

        return nil
    }

    private func handleConnectionFailure(_ error: Error) {
        guard isRunning else { return }

        log("Connection failure, attempting reconnect: \(error.localizedDescription)")

        // Attempt to cancel the tunnel — the system will auto-reconnect
        // if the user has "Connect on Demand" enabled
        let session = self as! NEPacketTunnelSession
        // In production: implement automatic reconnect logic
    }

    private func disconnectAndReconnect() {
        log("Disconnecting and reconnecting tunnel...")
        // In production: automatically attempt to reconnect
        // For now, let the system handle it
    }

    // MARK: - IPC Message Handler

    private func handleMessage(_ message: TunnelProviderMessage) async throws -> Data? {
        switch message {
        case .requestStats:
            let stats = TunnelStats(
                bytesReceived: bytesReceived,
                bytesSent: bytesSent,
                packetsProcessed: packetsProcessed,
                connectedSince: connectedAt ?? Date()
            )
            return try JSONEncoder().encode(stats)

        case .updateConfig(let config):
            // Update tunnel configuration dynamically
            let adapter = ProxyAdapterFactory.createAdapter(
                for: config.protocolType,
                password: config.password,
                method: config.method
            )
            self.adapter = adapter

            // Reconnect to new server
            if let oldConnection = proxyConnection {
                oldConnection.cancel()
            }

            try await connectToProxyServer(
                config: TunnelConfiguration(
                    from: ["tunnelConfig": try JSONEncoder().encode(config) as NSObject,
                           "nodeId": "updated" as NSObject,
                           "region": "updated" as NSObject]
                ),
                adapter: adapter
            )
            return nil

        case .requestStatus:
            let status = TunnelStatus(
                isConnected: isRunning && proxyConnection?.state == .ready,
                nodeId: config?.nodeId ?? "unknown",
                region: config?.region ?? "unknown",
                connectedAt: connectedAt,
                errorMessage: nil
            )
            return try JSONEncoder().encode(status)

        case .ping:
            return "pong".data(using: .utf8)
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        os_log("[IPSwitcher Tunnel] %{public}@", log: OSLog(subsystem: "com.ipswitcher.tunnel", category: "connection"), message)
    }
}

// MARK: - Convenience Extensions

extension PacketTunnelProvider {
    /// The packet flow for reading/writing tunnel packets
    var packetFlow: NEPacketTunnelFlow {
        return self.packetFlow
    }
}
