# Draft — Default Browser Entitlement Request

**To:** default-browser-requests@apple.com
**From:** (send from your primary Apple Developer account email, not an alias)
**Subject:** Web Browser Entitlement Requests — Sill (app.sill)

---

Hello,

I'm requesting the `com.apple.developer.web-browser` entitlement (and/or `com.apple.developer.default-web-browser` if that's the correct current identifier — please advise if these differ) for my macOS app:

- **App name:** Sill
- **Bundle identifier:** app.sill
- **Team ID:** AUEPCDGA5G
- **Distribution:** Developer ID (direct download + Sparkle auto-update), not App Store

Sill is a working macOS web browser built on WKWebView/the system WebKit engine. It:
- Handles `http`/`https` URL schemes (declared via `CFBundleURLTypes`)
- Provides full browsing chrome: tabs, workspaces, history, bookmarks, downloads, back/forward navigation
- Gives the user full control over page navigation (address bar, link-following, back/forward, reload)
- Persists real login sessions via a non-ephemeral `WKWebsiteDataStore`

I'd like this app to be eligible to appear as a default web browser option in System Settings, and to confirm whether the current download/file-handling restrictions I'm seeing without this entitlement are expected for apps without it.

I'm also requesting the `com.apple.developer.web-browser.public-key-credential` entitlement for the same app, so Sill can support passkeys via `ASAuthorizationWebBrowserPublicKeyCredentialManager` — as I understand it this is the mechanism third-party browsers use to offer platform passkeys on macOS. Happy to treat the two requests separately if they're reviewed on different tracks.

Please let me know if you need anything further to process either request.

Thank you,
Keran McKenzie
