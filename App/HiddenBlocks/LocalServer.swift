// LocalServer.swift — loopback-only HTTP server for the bundled editor.
//
// Why a server at all: the HiddenBlocks editor is a web app. Serving it
// from http://127.0.0.1 gives it a real HTTP origin, so localStorage and
// IndexedDB (project autosave, addon settings) behave exactly like they
// do on the website — file:// origins do not. The listener is bound to
// the loopback interface only; nothing is reachable from the network,
// and the app needs no internet connection at any point.
//
// Routing:
//   /                                -> Web/editor.html
//   /__scratch/<file>/get/          -> WebOffline/scratch/<file>
//   /__scratchhost/internalapi/...  -> WebOffline/scratch/<file>
//   /__pm/<path>                     -> WebOffline/pm/<path>
//   /__ext/turbowarp/<path>          -> WebOffline/ext/turbowarp/<path>
//   /__ext/penguinmod/<path>         -> WebOffline/ext/penguinmod/<path>
//   anything else                    -> Web/<path>
//
// The /__… routes exist because CI rewrites the editor's remote library
// hosts (Scratch CDN, PenguinMod library, extension galleries) to these
// loopback paths after prefetching every one of those files into the
// app bundle. See Scripts/offline_prefetch.py.

import Foundation
import Network

final class LocalServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.user.hiddenblocks.server", qos: .userInitiated)
    private let webRoot: URL
    private let offlineRoot: URL
    private(set) var port: UInt16 = 0
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?

    init(webRoot: URL, offlineRoot: URL) {
        self.webRoot = webRoot.standardizedFileURL
        self.offlineRoot = offlineRoot.standardizedFileURL
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: .any)
        } catch {
            onFailure?("Could not create listener: \(error)")
            return
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let boundPort = newListener.port {
                    self.port = boundPort.rawValue
                    self.onReady?(boundPort.rawValue)
                }
            case .failed(let error):
                self.onFailure?("Listener failed: \(error)")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.readRequest(connection, buffer: Data())
        }
        newListener.start(queue: queue)
    }

    // MARK: - Request reading

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: 0..<headerEnd.lowerBound)
                self.handle(connection, headerData: headerData)
                return
            }
            if error != nil || isComplete || accumulated.count > 65536 {
                self.respond(connection, status: 400, statusText: "Bad Request",
                             contentType: "text/plain", body: Data("Bad request".utf8))
                return
            }
            self.readRequest(connection, buffer: accumulated)
        }
    }

    private func handle(_ connection: NWConnection, headerData: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            respond(connection, status: 400, statusText: "Bad Request",
                    contentType: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: 400, statusText: "Bad Request",
                    contentType: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            // The editor only ever reads. Writes (e.g. the Scratch asset
            // store's create calls) are network features; fail fast so
            // the editor's fallbacks engage instead of hanging.
            respond(connection, status: 501, statusText: "Not Implemented",
                    contentType: "text/plain", body: Data("Writes are not supported offline".utf8))
            return
        }
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let fileURL = resolve(rawTarget) else {
            respond(connection, status: 404, statusText: "Not Found",
                    contentType: "text/plain", body: Data("Not found".utf8))
            return
        }
        serve(connection, fileURL: fileURL, headOnly: method == "HEAD", rangeHeader: rangeHeader)
    }

    // MARK: - Routing

    private func resolve(_ rawTarget: String) -> URL? {
        var target = rawTarget
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
        guard let decoded = target.removingPercentEncoding else { return nil }
        var path = decoded
        if path.isEmpty || path == "/" { path = "/editor.html" }

        func fileUnder(_ root: URL, _ relative: String) -> URL? {
            let clean = relative.split(separator: "/").filter { $0 != "." && $0 != ".." }
                .map(String.init).joined(separator: "/")
            let url = root.appendingPathComponent(clean).standardizedFileURL
            guard url.path.hasPrefix(root.path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            return url
        }

        if path.hasPrefix("/__scratch/") {
            // /__scratch/<md5ext>/get/ (thumbnail + asset URLs rewritten from the Scratch CDN)
            var rest = String(path.dropFirst("/__scratch/".count))
            if rest.hasSuffix("/get/") { rest = String(rest.dropLast(4)) }
            if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
            return fileUnder(offlineRoot.appendingPathComponent("scratch"), rest)
        }
        if path.hasPrefix("/__scratchhost/") {
            // /__scratchhost/internalapi/asset/<md5ext>/get/
            var rest = String(path.dropFirst("/__scratchhost/".count))
            if rest.hasPrefix("internalapi/asset/") { rest = String(rest.dropFirst("internalapi/asset/".count)) }
            if rest.hasSuffix("/get/") { rest = String(rest.dropLast(4)) }
            if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
            return fileUnder(offlineRoot.appendingPathComponent("scratch"), rest)
        }
        if path.hasPrefix("/__pm/") {
            return fileUnder(offlineRoot.appendingPathComponent("pm"), String(path.dropFirst("/__pm/".count)))
        }
        if path.hasPrefix("/__ext/") {
            return fileUnder(offlineRoot.appendingPathComponent("ext"), String(path.dropFirst("/__ext/".count)))
        }
        return fileUnder(webRoot, String(path.dropFirst()))
    }

    // MARK: - Response writing

    private func serve(_ connection: NWConnection, fileURL: URL, headOnly: Bool, rangeHeader: String?) {
        guard let data = try? Data(contentsOf: fileURL) else {
            respond(connection, status: 404, statusText: "Not Found",
                    contentType: "text/plain", body: Data("Not found".utf8))
            return
        }
        let contentType = Self.mimeType(for: fileURL.pathExtension.lowercased())
        if let rangeHeader, let range = Self.parseRange(rangeHeader, total: data.count) {
            let slice = data.subdata(in: range)
            let headers = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Type: \(contentType)\r\n"
                + "Content-Length: \(slice.count)\r\n"
                + "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n"
            send(connection, header: headers, body: headOnly ? nil : slice)
            return
        }
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        send(connection, header: headers, body: headOnly ? nil : data)
    }

    private func respond(_ connection: NWConnection, status: Int, statusText: String, contentType: String, body: Data) {
        let headers = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        send(connection, header: headers, body: body)
    }

    private func send(_ connection: NWConnection, header: String, body: Data?) {
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            if let body, !body.isEmpty {
                connection.send(content: body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                connection.cancel()
            }
        })
    }

    private static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        // Single byte range only: "bytes=start-end", "bytes=start-", "bytes=-suffix"
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil }
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        if pieces[0].isEmpty {
            guard let suffix = Int(pieces[1]), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return start..<total
        }
        guard let start = Int(pieces[0]), start >= 0, start < total else { return nil }
        if pieces[1].isEmpty { return start..<total }
        guard let end = Int(pieces[1]), end >= start else { return nil }
        return start..<min(end + 1, total)
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "cur": return "image/x-icon"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "wasm": return "application/wasm"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "map": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
