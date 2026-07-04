# M0 — Login viability spike

**Status: PASSED (4 July 2026). Google, GitHub, and Microsoft (Minecraft) sign-ins all
succeeded in-shell; sessions verified surviving full quit/relaunch. The WebKit path holds.**
PRD gate: if Google, GitHub, or Microsoft sign-in fails inside the shell after honest
effort, the WebKit path ends and the PoC pivots to the Chromium escape hatch (PRD §5 M0, §7).

## The configuration that matters

All of it lives in `Sources/Sill/TabStore.swift`; nothing else is load-bearing for logins.

1. **Persistent data store.** Every webview uses `WKWebsiteDataStore.default()` — one
   shared, non-ephemeral store (cookies, localStorage, IndexedDB, HSTS). Unsandboxed,
   it lives under `~/Library/WebKit/app.sill.poc/` and `~/Library/HTTPStorages/app.sill.poc/`.
   The bundle identifier (`app.sill.poc`, `Support/Info.plist`) is therefore part of the
   contract: change it and every login is lost.

2. **User agent byte-identical to Safari.** WebKit builds the UA as
   `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) <applicationName>`.
   The default `applicationName` includes the app's own name, which is what Google's
   "this browser or app may not be secure" wall keys off. We set
   `configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"`,
   yielding exactly Safari 26's UA. Verified live against whatismybrowser.com.

3. **Popups built from WebKit's configuration.** OAuth windows (`window.open`,
   `target=_blank`) arrive via `WKUIDelegate.webView(_:createWebViewWith:…)`. The new
   `WKWebView` **must** be constructed with the configuration WebKit passes in — that is
   what preserves the opener relationship login flows postMessage across. We open them
   as tabs and honour `webViewDidClose` so flows that close their own popup complete.

4. **JS panels answered.** `alert`/`confirm`/`prompt` are implemented as NSAlerts;
   silently dropping them stalls some login flows.

5. **App bundle, ad-hoc signed.** `make app` assembles `build/Sill.app` from the SwiftPM
   binary and `codesign --force --sign -` it. A stable, signed bundle keeps WebKit's
   storage and the OS's HTTP cookie storage attached to the same identity across builds.

## Automated checks already passed (4 July 2026)

- App builds, launches, renders, loads pages.
- UA string confirmed byte-identical to Safari via whatismybrowser.com inside the shell.
- accounts.google.com serves the real sign-in form (email + Next), not the
  embedded-webview block page.
- Session restore: tab URLs + selection persist across quit/relaunch
  (`UserDefaults` key `sill.session.v1`; cookie persistence is the data store's job).

## The owner's test (the actual M0 gate)

Run `make run`, then:

1. **Google** — sign in fully at accounts.google.com (password + any 2FA). The wall, if
   it comes, usually comes after the email step. Then open gmail.com and confirm you're in.
2. **GitHub** — sign in at github.com (including the device/2FA step if prompted).
3. **Microsoft** — sign in to one property (office.com / outlook.com / login.microsoftonline.com).
4. **Quit Sill entirely (⌘Q), relaunch** — all three must still be signed in with no
   re-auth prompt.

If all four pass, M0 is done and M1 (the real sidebar-first shell) starts.
If Google walls the sign-in: stop, write it up here, and open the Chromium escape hatch
per the PRD — no more WebKit code.

## Findings from the owner's test (4 July 2026)

- **Google: PASSED, with a passkey caveat.** No embedded-webview wall appeared; sign-in
  succeeded via a non-passkey method. **Passkeys do not work in-shell:** platform
  WebAuthn (Touch ID / iCloud Keychain) requires Apple's
  `com.apple.developer.web-browser.public-key-credential` entitlement, which needs a
  real provisioning-profile-signed browser build — not available to this ad-hoc-signed
  PoC. Google's fallback (phone-as-key over Bluetooth) rides the same blocked platform
  stack and dies with a misleading "make sure Bluetooth is on" error. Consequence for
  daily driving: sign in with passwords/TOTP inside Sill, not passkeys. This joins the
  password-manager gap as a known H5 sting (PRD §6) — log occurrences via the
  "that was annoying" counter, `password` tag. Revisit (proper signing + entitlement
  request, or `ASAuthorizationWebBrowserPublicKeyCredentialManager`) only if the PoC
  graduates.

## Notes

- ⌘L focuses the address field, ⌘T new tab, ⌘W close tab, ⌘R reload, ⌘[/⌘] history.
- The M0 shell (top tab strip, plain toolbar) is deliberately throwaway; M1 replaces it
  with the D2a sidebar-first chrome. Only `TabStore`/`BrowserTab`/`WebKitDelegate` carry forward.
- Known out-of-scope stings to expect while daily-driving later: no extensions (password
  manager via standalone app), no DRM (PRD §6).
