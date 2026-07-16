//
//  MermaidWebView.swift
//  MyaeEditor
//
//  An inline WKWebView that renders one mermaid diagram live and reports its
//  rendered height back to SwiftUI (so the block sizes to the diagram). Bundled
//  mermaid.min.js — fully offline. Rendering happens in the visible, in-hierarchy
//  web view, which is far more reliable than snapshotting an off-screen one.
//

import SwiftUI
import WebKit

enum MermaidTheme: String {
    case light = "default"
    case dark  = "dark"

    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
}

/// Cross-block cache of Mermaid's expensive parse/render result. Height is not
/// cached because the same responsive SVG can be installed at different editor
/// widths and measured cheaply in each web view.
enum MermaidRenderCache {
    struct Key: Hashable {
        let source: String
        let theme: MermaidTheme
        let rendererVersion = "11.16.0"
    }

    private static var values: [Key: String] = [:]
    private static var order: [Key] = []
    private static let limit = 64

    static func value(for key: Key) -> String? { values[key] }

    static func insert(_ svg: String, for key: Key) {
        if values[key] == nil { order.append(key) }
        values[key] = svg
        while order.count > limit {
            let oldest = order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    static func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    static var count: Int { values.count }
}

/// A WKWebView that forwards scroll-wheel events up the responder chain, so the
/// document keeps scrolling when the pointer is over an inline diagram. A plain
/// WKWebView swallows the gesture (its own scroll view eats it), trapping the
/// page scroll whenever the cursor is over a rendered mermaid block.
final class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct MermaidWebView: NSViewRepresentable {
    let source: String
    let theme: MermaidTheme
    /// Editor-card background hex, so the diagram blends with the block.
    let backgroundHex: String
    /// Rendered diagram height (CSS px), pushed back up so the block frames to it.
    @Binding var height: CGFloat
    /// Non-nil when mermaid reports a syntax error.
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = ScrollPassthroughWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // transparent; page paints its own bg
        web.autoresizingMask = [.width, .height]

        if let html = Bundle.module.url(forResource: "mermaid", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        context.coordinator.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Re-render only when the inputs that affect the diagram change.
        context.coordinator.requestRender(source: source, theme: theme, bg: backgroundHex)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: MermaidWebView
        weak var webView: WKWebView?
        private var pageReady = false
        private var lastKey: String?
        /// Held until the page finishes loading, then applied.
        private var pending: (source: String, theme: MermaidTheme, bg: String)?

        init(_ parent: MermaidWebView) { self.parent = parent }

        func requestRender(source: String, theme: MermaidTheme, bg: String) {
            let key = "\(source)|\(theme.rawValue)|\(bg)"
            guard key != lastKey else { return }   // nothing relevant changed
            lastKey = key
            pending = (source, theme, bg)
            if pageReady { flush() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            flush()
        }

        private func flush() {
            guard let req = pending, let web = webView else { return }
            pending = nil
            Task { await self.render(web: web, req: req) }
        }

        private func render(web: WKWebView, req: (source: String, theme: MermaidTheme, bg: String)) async {
            let trace = PerformanceTrace.begin("MermaidRender")
            defer { PerformanceTrace.end("MermaidRender", trace) }
            do {
                let cacheKey = MermaidRenderCache.Key(source: req.source, theme: req.theme)
                let height: Double
                if let svg = MermaidRenderCache.value(for: cacheKey) {
                    let result = try await web.callAsyncJavaScript(
                        "return await installMermaid(svg, bg);",
                        arguments: ["svg": svg, "bg": req.bg],
                        contentWorld: .page)
                    height = (result as? Double) ?? (result as? NSNumber)?.doubleValue ?? 0
                } else {
                    let result = try await web.callAsyncJavaScript(
                        "return await renderMermaid(code, theme, bg);",
                        arguments: ["code": req.source, "theme": req.theme.rawValue, "bg": req.bg],
                        contentWorld: .page)
                    let dictionary = result as? [String: Any]
                    let svg = dictionary?["svg"] as? String
                    height = (dictionary?["height"] as? Double)
                        ?? (dictionary?["height"] as? NSNumber)?.doubleValue ?? 0
                    if let svg { MermaidRenderCache.insert(svg, for: cacheKey) }
                }
                parent.errorMessage = nil
                parent.height = max(1, CGFloat(height))
            } catch {
                let ns = error as NSError
                let jsMsg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                parent.errorMessage = (jsMsg ?? ns.localizedDescription)
                    .replacingOccurrences(of: "Error: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
