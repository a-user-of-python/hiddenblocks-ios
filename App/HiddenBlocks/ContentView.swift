// ContentView.swift — boots the loopback server, then fills the whole
// screen with the editor. No browser chrome, no extra UI of our own:
// the editor IS the app, at natural scale (pageZoom 1.0, device-width
// viewport from the page itself).

import SwiftUI

struct ContentView: View {
    @State private var editorURL: URL?
    @State private var failureMessage: String?
    private let server: LocalServer

    init() {
        let bundle = Bundle.main
        let webRoot = bundle.url(forResource: "Web", withExtension: nil)
            ?? bundle.bundleURL.appendingPathComponent("Web")
        let offlineRoot = bundle.url(forResource: "WebOffline", withExtension: nil)
            ?? bundle.bundleURL.appendingPathComponent("WebOffline")
        server = LocalServer(webRoot: webRoot, offlineRoot: offlineRoot)
    }

    var body: some View {
        Group {
            if let editorURL {
                WebView(url: editorURL)
                    .ignoresSafeArea()
            } else if let failureMessage {
                VStack(spacing: 16) {
                    Text("HiddenBlocks could not start")
                        .font(.headline)
                    Text(failureMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading HiddenBlocks…")
                        .font(.headline)
                }
            }
        }
        .onAppear {
            server.onReady = { port in
                DispatchQueue.main.async {
                    if editorURL == nil {
                        editorURL = URL(string: "http://127.0.0.1:\(port)/editor.html")
                    }
                }
            }
            server.onFailure = { message in
                DispatchQueue.main.async {
                    if editorURL == nil {
                        failureMessage = message
                    }
                }
            }
            server.start()
        }
    }
}
