import SafariServices
import SwiftUI
import WebKit

enum LegalLinks {
    /// Rakful uses Apple's standard EULA as its Terms of Use.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// The privacy policy ships in the app bundle so it's available offline.
    /// The same file is what gets hosted for the App Store listing.
    static let bundledPrivacyPolicy = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html")
}

struct PrivacyPolicyView: View {
    var body: some View {
        Group {
            if let url = LegalLinks.bundledPrivacyPolicy {
                BundledWebView(fileURL: url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Privacy Policy Unavailable", systemImage: "doc.text")
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shows a local HTML file; links out of it open in Safari.
private struct BundledWebView: UIViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, !url.isFileURL else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}
