import Foundation

/// SwiftPM's generated `Bundle.module` accessor for the executable searches
/// only the .app root and the build machine's absolute `.build` path, then
/// traps — so a packaged app crashes at launch on any other machine (the
/// bundles ride in Contents/Resources). Launch paths resolve bundles here
/// instead: packaged location first, executable directory for dev builds,
/// nil rather than a trap when missing.
public enum ResourceBundle {
    public static func locate(
        named name: String,
        searching candidates: [URL?] = [Bundle.main.resourceURL, Bundle.main.bundleURL]
    ) -> Bundle? {
        for case let dir? in candidates {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}
