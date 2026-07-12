import Foundation

final class IPChecker {
    static let shared = IPChecker()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - IP Detection

    /// Get current public IP from multiple sources for reliability
    func checkCurrentIP() async throws -> IPInfo {
        // Try primary source
        if let info = try? await fetchFromIPify() {
            return info
        }

        // Try secondary source
        if let info = try? await fetchFromHTTPBin() {
            return info
        }

        // Try tertiary source
        if let info = try? await fetchFromIPAPI() {
            return info
        }

        throw IPCheckerError.allSourcesFailed
    }

    /// Quick IP-only check (faster, no geo info)
    func quickIPCheck() async throws -> String {
        let url = URL(string: "https://api.ipify.org")!
        let (data, _) = try await session.data(from: url)
        guard let ip = String(data: data, encoding: .utf8), !ip.isEmpty else {
            throw IPCheckerError.invalidResponse
        }
        return ip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sources

    private func fetchFromIPify() async throws -> IPInfo {
        struct IPifyResponse: Codable {
            let ip: String
        }

        let url = URL(string: "https://api.ipify.org?format=json")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(IPifyResponse.self, from: data)

        // Get geo info in parallel
        async let geo = fetchGeoInfo(ip: response.ip)

        return try await IPInfo(
            ip: response.ip,
            country: geo.country,
            countryCode: geo.countryCode,
            region: geo.region,
            city: geo.city,
            isp: geo.isp,
            latitude: geo.lat,
            longitude: geo.lon,
            timezone: geo.timezone
        )
    }

    private func fetchFromHTTPBin() async throws -> IPInfo {
        struct HTTPBinResponse: Codable {
            let origin: String
        }

        let url = URL(string: "https://httpbin.org/ip")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(HTTPBinResponse.self, from: data)

        let ip = response.origin.components(separatedBy: ", ").first ?? response.origin

        async let geo = fetchGeoInfo(ip: ip)
        return try await IPInfo(
            ip: ip,
            country: geo.country,
            countryCode: geo.countryCode,
            region: geo.region,
            city: geo.city,
            isp: geo.isp,
            latitude: geo.lat,
            longitude: geo.lon,
            timezone: geo.timezone
        )
    }

    private func fetchFromIPAPI() async throws -> IPInfo {
        struct IPAPIResponse: Codable {
            let query: String
            let country: String
            let countryCode: String
            let region: String
            let city: String
            let isp: String
            let lat: Double
            let lon: Double
            let timezone: String
        }

        let url = URL(string: "https://ip-api.com/json/")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(IPAPIResponse.self, from: data)

        return IPInfo(
            ip: response.query,
            country: response.country,
            countryCode: response.countryCode.lowercased(),
            region: response.region,
            city: response.city,
            isp: response.isp,
            latitude: response.lat,
            longitude: response.lon,
            timezone: response.timezone
        )
    }

    private func fetchGeoInfo(ip: String) async throws -> GeoInfo {
        struct GeoResponse: Codable {
            let country: String?
            let countryCode: String?
            let region: String?
            let city: String?
            let isp: String?
            let lat: Double?
            let lon: Double?
            let timezone: String?
        }

        do {
            let url = URL(string: "http://ip-api.com/json/\(ip)")!
            let (data, _) = try await session.data(from: url)
            let geo = try JSONDecoder().decode(GeoResponse.self, from: data)
            return GeoInfo(
                country: geo.country ?? "Unknown",
                countryCode: (geo.countryCode ?? "xx").lowercased(),
                region: geo.region ?? "",
                city: geo.city ?? "",
                isp: geo.isp ?? "",
                lat: geo.lat ?? 0,
                lon: geo.lon ?? 0,
                timezone: geo.timezone ?? "UTC"
            )
        } catch {
            return GeoInfo(
                country: "Unknown",
                countryCode: "xx",
                region: "",
                city: "",
                isp: "",
                lat: 0,
                lon: 0,
                timezone: "UTC"
            )
        }
    }
}

// MARK: - Supporting Types

private struct GeoInfo {
    let country: String
    let countryCode: String
    let region: String
    let city: String
    let isp: String
    let lat: Double
    let lon: Double
    let timezone: String
}

enum IPCheckerError: LocalizedError {
    case allSourcesFailed
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .allSourcesFailed:
            return "所有 IP 检测源均不可用"
        case .invalidResponse:
            return "服务器返回了无效响应"
        case .timeout:
            return "请求超时"
        }
    }
}
