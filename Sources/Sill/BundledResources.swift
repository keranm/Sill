import Foundation

/// Resolves the SwiftPM resource bundle (fonts, blocklists) directly, instead
/// of via the auto-generated `Bundle.module` accessor.
///
/// That generated accessor's primary path is `Bundle.main.bundleURL` +
/// "Sill_Sill.bundle" — correct for a bare `swift run`/`.build/debug/Sill`
/// execution (the resource bundle sits next to the executable there), but
/// wrong for our hand-assembled `.app`, where the real macOS convention
/// (`Contents/Resources/`) puts it one level deeper. Its fallback is a
/// hardcoded *absolute path into the dev machine's own `.build` directory* —
/// which is why this went unnoticed for multiple releases: it only ever ran
/// on the machine that built it, where that fallback happened to exist. A
/// real crash report from a fresh install (`Bundle.module`'s fatalError)
/// caught it — every other machine has neither path.
enum BundledResources {
    static let bundle: Bundle? = {
        let name = "Sill_Sill.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),  // real .app: Contents/Resources/
            Bundle.main.bundleURL.appendingPathComponent(name),     // swift run / bare .build/*/Sill
        ]
        for candidate in candidates {
            if let candidate, let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }()
}
