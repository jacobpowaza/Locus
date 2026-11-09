import Foundation
#if !targetEnvironment(simulator)
import idevice
#endif

enum LocationEngineError: LocalizedError {
    case invalidCoordinate
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return "Choose a valid location."
        case .invalidIP: return "Check the connection address in Advanced Settings."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Couldn’t reach the iPhone’s location service. Check Connection in Settings."
        case .remoteServer: return "The iPhone didn’t complete the connection. Check Connection in Settings."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

#if !targetEnvironment(simulator)
/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        guard GeoPoint(latitude: latitude, longitude: longitude).isValid else { return .failure(.invalidCoordinate) }
        return await withCheckedContinuation { continuation in
            queue.async {
                let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
                continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
            }
        }
    }

    static func clear(pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let code = clearLocked(pairingPath: pairingPath, deviceIP: deviceIP)
                continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
            }
        }
    }

    private static func recordError(_ error: UnsafeMutablePointer<IdeviceFfiError>, stage: String) {
        // Native error strings can include endpoint or pairing information.
        NSLog("[Locus][Connection] %@ failed (idevice %d/%d)", stage, error.pointee.code, error.pointee.sub_code)
        idevice_error_free(error)
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        if let locationSimulation {
            if let error = location_simulation_set(locationSimulation, latitude, longitude) {
                recordError(error, stage: "Update location")
                cleanup()
                // Retry on the next session tick, keeping the last confirmed position.
                return locationSet
            }
            return ok
        }
        let opened = openLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        guard opened == ok, let locationSimulation else { return opened == ok ? simulationCreate : opened }
        if let error = location_simulation_set(locationSimulation, latitude, longitude) {
            recordError(error, stage: "Set initial location")
            cleanup()
            return locationSet
        }
        return ok
    }

    private static func openLocked(pairingPath: String, deviceIP: String) -> Int32 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            recordError(pairingError, stage: "Read pairing record")
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            recordError(providerError, stage: "RemotePairing tunnel on TCP 49152")
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            recordError(remoteServerError, stage: "RemoteXPC service handshake")
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            recordError(simError, stage: "Open DVT location service")
            cleanup()
            return simulationCreate
        }
        // location_simulation_new consumes/owns remote server lifecycle alongside handle
        remoteServer = nil

        return ok
    }

    private static func clearLocked(pairingPath: String, deviceIP: String) -> Int32 {
        if locationSimulation == nil {
            let opened = openLocked(pairingPath: pairingPath, deviceIP: deviceIP)
            guard opened == ok else { return opened }
        }
        guard let locationSimulation else { return locationClear }
        let error = location_simulation_clear(locationSimulation)
        cleanup()
        if let error {
            recordError(error, stage: "Clear simulated location")
            return locationClear
        }
        return ok
    }
}
#else
/// iOS Simulator stand-in. `libidevice_ffi.a` is built for iOS devices only
/// and there is no developer tunnel in the Simulator, so this just records
/// coordinates and logs them (grep the device log for "[Locus][SimStub]").
/// It lets the UI, Scheduled Runs and everything except real spoofing be
/// exercised in the Simulator. Use `xcrun simctl location` to move the
/// Simulator's own location if needed.
enum LocationEngine {
    private static var active: (Double, Double)?

    @MainActor static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        active = (latitude, longitude)
        NSLog("[Locus][SimStub] set %.6f,%.6f", latitude, longitude)
        return .success(())
    }

    @MainActor static func clear(pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        active = nil
        NSLog("[Locus][SimStub] clear")
        return .success(())
    }
}
#endif
