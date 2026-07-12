import Foundation
import WebKit

final class WebRTCLeakDetector: NSObject {
    static let shared = WebRTCLeakDetector()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String], Error>?

    // MARK: - Leak Detection

    /// Check if the current connection leaks the real IP via WebRTC
    /// Returns a list of leaked IPs (empty if no leak detected)
    func detectLeaks(tunnelIP: String?) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: WebRTCError.detectorDeallocated)
                    return
                }

                let config = WKWebViewConfiguration()
                // Disable JavaScript autoplay
                config.mediaTypesRequiringUserActionForPlayback = .all

                let webView = WKWebView(frame: .zero, configuration: config)
                webView.navigationDelegate = self
                self.webView = webView

                // Load the leak test HTML
                let html = self.buildLeakTestPage()
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    /// Build a self-contained HTML page with WebRTC leak test
    private func buildLeakTestPage() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        <script>
        function getIPs(callback) {
            var ips = [];
            var pc = new RTCPeerConnection({ iceServers: [] });
            pc.createDataChannel('');
            pc.createOffer().then(function(offer) {
                pc.setLocalDescription(offer);
            });
            pc.onicecandidate = function(event) {
                if (event.candidate) {
                    var candidate = event.candidate.candidate;
                    var ipRegex = /([0-9]{1,3}(\\.[0-9]{1,3}){3}|[a-f0-9:]+:[a-f0-9:]+)/g;
                    var match;
                    while ((match = ipRegex.exec(candidate)) !== null) {
                        if (ips.indexOf(match[1]) === -1) {
                            ips.push(match[1]);
                        }
                    }
                } else {
                    callback(ips);
                }
            };
            setTimeout(function() {
                callback(ips);
            }, 3000);
        }
        getIPs(function(ips) {
            document.body.innerText = JSON.stringify(ips);
        });
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKNavigationDelegate

extension WebRTCLeakDetector: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait 3 seconds for ICE candidates to gather
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            webView.evaluateJavaScript("document.body.innerText") { result, error in
                if let error = error {
                    self.continuation?.resume(throwing: WebRTCError.javaScriptError(error))
                    self.continuation = nil
                    return
                }

                if let jsonString = result as? String,
                   let data = jsonString.data(using: .utf8),
                   let ips = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    self.continuation?.resume(returning: ips)
                } else {
                    self.continuation?.resume(returning: [])
                }
                self.continuation = nil
                self.webView = nil
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: WebRTCError.detectionFailed(error))
        continuation = nil
        self.webView = nil
    }
}

// MARK: - Errors

enum WebRTCError: LocalizedError {
    case detectorDeallocated
    case javaScriptError(Error)
    case detectionFailed(Error)
    case webViewNotAvailable

    var errorDescription: String? {
        switch self {
        case .detectorDeallocated:
            return "检测器已被释放"
        case .javaScriptError(let error):
            return "JavaScript 执行错误: \(error.localizedDescription)"
        case .detectionFailed(let error):
            return "WebRTC 检测失败: \(error.localizedDescription)"
        case .webViewNotAvailable:
            return "WebView 不可用"
        }
    }
}
