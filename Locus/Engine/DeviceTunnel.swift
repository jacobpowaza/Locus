import Foundation

enum TunnelConfig {
    /// LocalDevVPN / SideStore-style loopback tunnel endpoint.
    static let defaultIP = "10.7.0.1"
    static let defaultsKey = "locus.targetDeviceIP"

    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultIP }
        return stored
    }

    static var embeddedProvider: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundles = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return false }
        return bundles.contains { url in
            guard let extensionInfo = Bundle(url: url)?.infoDictionary?["NSExtension"] as? [String: Any] else { return false }
            return extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
        }
    }

    static func setTargetIP(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}
