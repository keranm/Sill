import AppKit
import SwiftUI
import WebKit

/// Glance (Arc's "Peek"): a lightweight preview layered over the current
/// window — not a separate OS window (that's Quick Look) — shown when a
/// link inside a Pinned/Favorited tab points outside its home domain.
/// Expand promotes it into a real tab in the current workspace; otherwise
/// close it (click outside, the X, or Cmd-W) and it's gone, no trace.
///
/// No Split View button yet: Sill has no split-view feature to drop into.
struct GlanceView: View {
    @Bindable var store: TabStore
    let url: URL

    @State private var tab: BrowserTab?
    /// Set just before expanding, so .onDisappear doesn't tear down the
    /// webview that was just adopted into the workspace.
    @State private var expanded = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                header
                content
            }
            .frame(width: 900, height: 660)
            .background(Tokens.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
        .transition(.opacity)
        .onAppear {
            guard tab == nil else { return }
            let newTab = BrowserTab(url: url) {}
            tab = newTab
            store.materialize(newTab)
        }
        .onDisappear {
            if let tab, !expanded { Task { await tab.dehydrate() } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                tab?.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle((tab?.canGoBack ?? false) ? Tokens.inkFaint : Tokens.inkGhost.opacity(0.5))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(tab?.canGoBack ?? false))
            .arrowCursor()

            addressReadout

            Spacer(minLength: 8)

            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.inkFaint)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open in this workspace")
            .arrowCursor()

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.inkFaint)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .arrowCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var addressReadout: some View {
        let host = tab?.url?.host() ?? url.host() ?? ""
        let domain = HostDisplay.displayHost(HostDisplay.registrableDomain(of: host))
        return Text(domain)
            .font(Tokens.font(12.5, .medium))
            .foregroundStyle(Tokens.ink)
            .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        if let tab, let webView = tab.webView, tab.url != nil {
            WebViewContainer(webView: webView)
        } else {
            Tokens.stage
        }
    }

    private func expand() {
        guard let tab else { return }
        expanded = true
        store.adopt(tab, into: store.activeWorkspace)
        store.glanceURL = nil
    }

    private func dismiss() {
        store.glanceURL = nil
    }
}

private extension View {
    /// Glance draws over the pinned tab's own WKWebView, which still owns
    /// native AppKit cursor-rects for whatever's underneath (e.g. a text
    /// field on the actual page at that screen position) — without this,
    /// the stale I-beam/etc bleeds through the overlay's buttons.
    func arrowCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
