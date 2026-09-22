import Foundation
import Network

/// Finds SMB servers on the current Wi-Fi network by probing every address in the device's own /24 subnet for an
/// open port 445 (SMB) — a plain Windows PC share does not advertise itself via Bonjour/mDNS the way a NAS or Mac
/// does, so a direct port scan of the LAN (the same technique most network file-browser apps use) is the reliable
/// way to find it, matching what the Android app's own network discovery achieves.
enum SmbDiscovery {
    struct Found: Identifiable, Hashable {
        var id: String { host }
        let host: String
    }

    /// Scans the local /24 subnet; calls `progress(checked, total)` (off the main thread) as it goes. Returns hosts
    /// with port 445 open, sorted by address. Returns an empty list if the device's own Wi-Fi IP can't be read.
    static func scanLocalNetwork(progress: @escaping (Int, Int) -> Void) async -> [Found] {
        guard let localIP = currentWiFiIPv4Address(), let prefix = subnetPrefix(of: localIP) else { return [] }

        let hosts = (1...254).map { "\(prefix).\($0)" }
        let total = hosts.count
        let counter = ProgressCounter()

        return await withTaskGroup(of: Found?.self) { group in
            for host in hosts {
                group.addTask {
                    let isOpen = await probe(host: host, port: 445, timeout: 0.6)
                    let current = await counter.increment()
                    progress(current, total)
                    return isOpen ? Found(host: host) : nil
                }
            }
            var results: [Found] = []
            for await found in group {
                if let found { results.append(found) }
            }
            return results.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        }
    }

    private actor ProgressCounter {
        private var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    private static func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let resumeLock = NSLock()
            var resumed = false
            func finish(_ result: Bool) {
                resumeLock.lock()
                guard !resumed else { resumeLock.unlock(); return }
                resumed = true
                resumeLock.unlock()
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// The device's own IPv4 address on the Wi-Fi interface (`en0`), read via the standard POSIX `getifaddrs` API.
    private static func currentWiFiIPv4Address() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            ptr = interface.ifa_next
        }
        return address
    }

    private static func subnetPrefix(of ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts[0...2].joined(separator: ".")
    }
}
