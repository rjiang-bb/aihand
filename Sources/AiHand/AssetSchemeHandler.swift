import Foundation
import WebKit

/// Serves vendored web assets (Monaco) to the transcript WKWebView as `aihand-asset://app/<path>`.
///
/// The transcript shell is loaded with this scheme as its base URL so Monaco's AMD loader and
/// workers are same-origin.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "aihand-asset"
    static let baseURL = URL(string: "\(scheme)://app/")!

    /// Directories that may be served, keyed by their first path component.
    private let roots: [String: URL]

    init(roots: [String: URL] = AssetSchemeHandler.defaultRoots()) {
        self.roots = roots
    }

    /// Served folders (`monaco`, `codeview`): app bundle Resources first, repo `assets/` for `swift run` / `swift test`.
    static func defaultRoots() -> [String: URL] {
        let probes = ["monaco": "vs/loader.js", "codeview": "codeview.js"]
        let repoAssets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets")
        var out: [String: URL] = [:]
        for (name, probe) in probes {
            if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
               FileManager.default.fileExists(atPath: res.appendingPathComponent(probe).path) {
                out[name] = res
            } else {
                out[name] = repoAssets.appendingPathComponent(name)
            }
        }
        return out
    }

    /// Resolves a scheme URL to a file inside an allowed root, or nil (missing / traversal).
    func fileURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let components = url.path.split(separator: "/").map(String.init)
        guard let first = components.first, let root = roots[first] else { return nil }
        let rest = components.dropFirst()
        guard !rest.isEmpty, !rest.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            return nil
        }
        let candidate = rest.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "html": return "text/html"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let file = fileURL(for: url),
              let data = try? Data(contentsOf: file) else {
            let url = urlSchemeTask.request.url ?? Self.baseURL
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: file),
                "Content-Length": String(data.count),
                "Cache-Control": "max-age=31536000",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
