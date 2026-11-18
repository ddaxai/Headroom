import Foundation

/// Constants shared by the GUI probe, the standalone helper, and launchd metadata.
/// Keeping the health contract in the dependency-free core prevents the two listeners from
/// silently drifting apart while S5 adds the request protocol.
public enum LocalMeterEndpoint {
    public static let defaultPort: UInt16 = 47891
    public static let healthPath = "/__headroom/local-meter/health"
    public static let healthHeader = "X-Headroom-Local-Meter"
    public static let healthSignature = "1"

    public static func baseURL(port: UInt16 = Self.defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
