//
//  MermaidZoomView.swift
//  MyaeEditor
//
//  A full-size, zoomable/pannable viewer for one mermaid diagram, shown as a
//  sheet from the inline mermaid block. Reuses the bundled mermaid runtime via a
//  dedicated `mermaid-zoom.html` that adds pan (drag) + zoom (wheel / buttons).
//

import SwiftUI
import WebKit

/// Bridges the zoom toolbar buttons to the web view's JavaScript pan/zoom API.
/// The web view registers itself on `makeNSView` and marks itself ready once the
/// page has loaded, so a button tapped before the JS is defined is a safe no-op.
@MainActor
final class MermaidZoomController {
    fileprivate weak var webView: WKWebView?
    fileprivate var ready = false

    private func run(_ js: String) {
        guard ready, let webView else { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    func zoomIn()  { run("zoomBy(1.25)") }
    func zoomOut() { run("zoomBy(0.8)") }
    func reset()   { run("resetZoom()") }
}

/// Sheet content: the diagram fills the space, with a floating toolbar for zoom
/// in / out / reset and a Done button.
struct MermaidZoomView: View {
    let source: String
    let theme: MermaidTheme
    var onClose: () -> Void

    @State private var controller = MermaidZoomController()
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            MermaidZoomWebView(source: source, theme: theme,
                               controller: controller, errorMessage: $errorMessage)
                .background(Color(nsColor: .windowBackgroundColor))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 60)
            }

            toolbar
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 460, idealHeight: 640)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton("minus.magnifyingglass", "Zoom out") { controller.zoomOut() }
            toolButton("arrow.up.left.and.down.right.magnifyingglass", "Fit") { controller.reset() }
            toolButton("plus.magnifyingglass", "Zoom in") { controller.zoomIn() }
            Divider().frame(height: 16)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        .padding(.top, 12)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func toolButton(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13)).frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// WKWebView that loads `mermaid-zoom.html`, renders the diagram once the page is
/// ready, and exposes its JS pan/zoom API to the `MermaidZoomController`.
struct MermaidZoomWebView: NSViewRepresentable {
    let source: String
    let theme: MermaidTheme
    let controller: MermaidZoomController
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.autoresizingMask = [.width, .height]
        // Transparent so the sheet's window background shows through and matches
        // the inline diagram (which also renders on a transparent page).
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = web
        controller.webView = web

        if let html = Bundle.module.url(forResource: "mermaid-zoom", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.requestRender(source: source, theme: theme)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: MermaidZoomWebView
        weak var webView: WKWebView?
        private var pageReady = false
        /// Last-rendered inputs, so a redundant `updateNSView` doesn't re-render
        /// (which would reset the user's zoom/pan). Mirrors `MermaidWebView`.
        private var lastKey: String?
        private var pending: (source: String, theme: MermaidTheme)?

        init(_ parent: MermaidZoomWebView) { self.parent = parent }

        func requestRender(source: String, theme: MermaidTheme) {
            let key = "\(source)|\(theme.rawValue)"
            guard key != lastKey else { return }   // nothing relevant changed
            lastKey = key
            pending = (source, theme)
            if pageReady { flush() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            parent.controller.ready = true   // now safe to run zoom-button JS
            flush()
        }

        private func flush() {
            guard let req = pending, let web = webView else { return }
            pending = nil
            Task { await render(web: web, req: req) }
        }

        private func render(web: WKWebView, req: (source: String, theme: MermaidTheme)) async {
            // Transparent page — the sheet's window background shows through, so
            // the diagram blends the same way the inline block does.
            do {
                _ = try await web.callAsyncJavaScript(
                    "return await renderMermaid(code, theme, bg);",
                    arguments: ["code": req.source, "theme": req.theme.rawValue, "bg": "transparent"],
                    contentWorld: .page)
                parent.errorMessage = nil
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
