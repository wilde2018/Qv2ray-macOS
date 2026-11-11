import Foundation

/// Binaries and data embedded in the app bundle by `support/make-app.sh`:
/// `Contents/MacOS/{xray,tun2socks}` and `Contents/Resources/core/{geoip,geosite}.dat`.
/// Everything is nil when running unbundled (`swift run`) or from a slim build.
enum BundledTools {
    private static var executableDir: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    private static func executable(_ name: String) -> String? {
        guard Bundle.main.bundleIdentifier != nil,
              let path = executableDir?.appendingPathComponent(name).path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static var xray: String? { executable("xray") }
    static var tun2socks: String? { executable("tun2socks") }

    /// The bundled geodata directory, if it holds geoip.dat or geosite.dat.
    static var assetsDir: URL? {
        guard Bundle.main.bundleIdentifier != nil,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("core", isDirectory: true) else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("geoip.dat").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("geosite.dat").path) else { return nil }
        return dir
    }

    /// Whether `path` is one of the binaries shipped inside this app.
    static func isBundled(_ path: String) -> Bool {
        guard let dir = executableDir, !path.isEmpty else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path == dir.path
    }
}
