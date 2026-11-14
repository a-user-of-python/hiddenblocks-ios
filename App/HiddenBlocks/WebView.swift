// WebView.swift — full-screen WKWebView hosting the bundled editor.
//
// Offline enforcement, two layers:
//  1. A WKContentRuleList blocks every http:// and https:// subresource
//     load whose host is not loopback. The editor is served from
//     127.0.0.1, and CI rewrites its library/extension hosts to loopback
//     paths, so nothing the editor needs is external — anything still
//     pointing outside (PenguinMod accounts, cloud projects, loading a
//     custom extension from a URL) is a network feature and is blocked.
//  2. The navigation delegate cancels non-loopback main-frame
//     navigations; a user-tapped external link opens in Safari instead
//     of replacing the editor.
//
// Downloads (project export .pmp/.sb3, costume/sound export) are saved
// into the app's Documents/Downloads folder and offered via a share
// sheet, because WKWebView has no download UI of its own.

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.pageZoom = 1.0
        context.coordinator.webView = webView

        // Compile the offline content rule list first, then load, so the
        // very first page load is already covered by the rules.
        let rules = """
        [{"trigger":{"url-filter":"^https?://","unless-domain":["127.0.0.1","localhost"]},\
        "action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "offline-only",
            encodedContentRuleList: rules
        ) { ruleList, _ in
            DispatchQueue.main.async {
                if let ruleList {
                    webView.configuration.userContentController.add(ruleList)
                }
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The editor is a single-page app; the URL never changes.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        weak var webView: WKWebView?
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]

        private func isLoopback(_ url: URL?) -> Bool {
            guard let host = url?.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let target = navigationAction.request.url
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            guard let target else {
                decisionHandler(.cancel)
                return
            }
            if isLoopback(target) || target.scheme == "blob" || target.scheme == "data"
                || target.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            // Non-loopback main-frame navigation: never replace the editor.
            // A link the user actually tapped opens in Safari instead.
            if navigationAction.navigationType == .linkActivated,
               target.scheme == "http" || target.scheme == "https" {
                UIApplication.shared.open(target)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView,
                     navigationAction: WKNavigationAction,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView,
                     navigationResponse: WKNavigationResponse,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: WKDownloadDelegate

        func download(_ download: WKDownload,
                      decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            do {
                let documents = try FileManager.default.url(
                    for: .documentDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var destination = folder.appendingPathComponent(suggestedFilename)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let ext = destination.pathExtension
                    let base = destination.deletingPathExtension().lastPathComponent
                    var counter = 2
                    repeat {
                        let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                        destination = folder.appendingPathComponent(name)
                        counter += 1
                    } while FileManager.default.fileExists(atPath: destination.path)
                }
                downloadDestinations[ObjectIdentifier(download)] = destination
                completionHandler(destination)
            } catch {
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let savedURL = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            else { return }
            presentShareSheet(for: savedURL)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            print("HiddenBlocks: download failed: \(error)")
        }

        private func presentShareSheet(for fileURL: URL) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else { return }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let share = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            share.popoverPresentationController?.permittedArrowDirections = []
            presenter.present(share, animated: true)
        }

        // MARK: WKUIDelegate

        // Camera / microphone for video sensing and the sound recorder.
        // The editor only ever runs from the app's own bundled origin, so
        // capture permission for that origin is granted; the system-level
        // prompt still appears the first time (Info.plist usage strings).
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            if origin.host == "127.0.0.1" || origin.host == "localhost" {
                decisionHandler(.grant)
            } else {
                decisionHandler(.deny)
            }
        }
    }
}
