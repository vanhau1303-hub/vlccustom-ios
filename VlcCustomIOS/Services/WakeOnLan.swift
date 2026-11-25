import Darwin
import Foundation
import Network

/// How to wake one saved SMB server (keyed by its host): its network card's MAC address, where to send the magic
/// packet on the home network, and — from outside — the DDNS name and UDP port the router forwards.
struct WakeTarget: Codable, Equatable {
    var mac = ""
    /// The PC's address in the home network ("192.168.1.242"): the packet is also sent straight to it.
    var lanAddress = ""
    /// From outside (4G, another Wi-Fi): the router's DDNS name ("nhabadiem.duckdns.org"); the router has to forward
    /// `wanPort` (UDP) to the PC or to the LAN's broadcast address.
    var wanHost = ""
    var wanPort = 9
    /// Wake it on its own when it does not answer, then connect.
    var autoWake = true

    var isConfigured: Bool { WakeOnLan.macBytes(mac) != nil }
}

/// Wake-on-LAN settings per server, in UserDefaults.
enum WakeTargetStore {
    private static let key = "wol_targets"

    private static var all: [String: WakeTarget] {
        get {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([String: WakeTarget].self, from: $0) } ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    static func target(for host: String) -> WakeTarget? { all[host.lowercased()] }

    static func save(_ target: WakeTarget, for host: String) {
        var all = self.all
        all[host.lowercased()] = target
        self.all = all
    }

    /// A configured target that wakes on its own when the server does not answer.
    static func autoTarget(for host: String) -> WakeTarget? {
        guard let target = target(for: host), target.isConfigured, target.autoWake else { return nil }
        return target
    }
}

/// Wake-on-LAN: the "magic packet" (6 × 0xFF, then the MAC address 16 times) over UDP.
///
/// Sent every way that can reach the PC, since each works in different situations:
/// - the LAN broadcast (255.255.255.255 and the Wi-Fi subnet's, ports 9 and 7) — the classic way; iOS may refuse
///   broadcasts from an app without Apple's multicast permission, so it is not the only one;
/// - straight to the PC's LAN address — works while the router still remembers where that address is;
/// - to the DDNS name and port — from outside, and from inside too when the router loops it back; the router
///   forwards that UDP port to the PC (or to 192.168.1.255).
enum WakeOnLan {
    /// "50-EB-F6-5B-7A-48", "50:eb:f6:5b:7a:48", "50EBF65B7A48" → 6 bytes.
    static func macBytes(_ text: String) -> [UInt8]? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func packet(_ mac: [UInt8]) -> Data {
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac) }
        return data
    }

    /// Sends the packet every way (three times each, a moment apart) and says what went out.
    static func wake(_ target: WakeTarget) async -> [String] {
        guard let mac = macBytes(target.mac) else { return ["MAC không hợp lệ"] }
        let data = packet(mac)
        var routes: [(host: String, port: UInt16, broadcast: Bool, label: String)] = [
            ("255.255.255.255", 9, true, "LAN broadcast"),
            ("255.255.255.255", 7, true, "LAN broadcast :7"),
        ]
        if let subnet = wifiBroadcastAddress() {
            routes.append((subnet, 9, true, "LAN \(subnet)"))
        }
        let lan = target.lanAddress.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty { routes.append((lan, 9, false, "máy \(lan)")) }
        let wan = target.wanHost.trimmingCharacters(in: .whitespaces)
        if !wan.isEmpty {
            routes.append((wan, UInt16(clamping: max(1, min(65535, target.wanPort))), false, "\(wan):\(target.wanPort)"))
        }

        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var report: [String] = []
            for round in 0..<3 {
                for route in routes {
                    let error = send(data, to: route.host, port: route.port, broadcast: route.broadcast)
                    if round == 0 { report.append("\(route.label): \(error ?? "đã gửi")") }
                }
                usleep(300_000)
            }
            PlaybackDiagnostics.append("wol: " + report.joined(separator: " · "))
            return report
        }.value
    }

    /// One UDP datagram; nil when it went out, else the reason.
    private static func send(_ data: Data, to host: String, port: UInt16, broadcast: Bool) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return "không tìm được địa chỉ" }
        defer { freeaddrinfo(info) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "không mở được socket" }
        defer { close(fd) }
        if broadcast {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let sent = data.withUnsafeBytes { raw in
            sendto(fd, raw.baseAddress, data.count, 0, first.pointee.ai_addr, first.pointee.ai_addrlen)
        }
        return sent == data.count ? nil : "lỗi \(String(cString: strerror(errno)))"
    }

    /// The Wi-Fi subnet's broadcast address ("192.168.1.255"), from the phone's own address and netmask.
    private static func wifiBroadcastAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            var broadcast = in_addr(s_addr: ip | ~netmask)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    /// Waits until `host` answers on the SMB port (445), up to `timeout`; `progress` gets the seconds waited.
    static func waitForSmb(host: String, timeout: TimeInterval, progress: @escaping @MainActor (Int) -> Void) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return false }
            if await portOpen(host: host, port: 445, within: 3) { return true }
            await progress(Int(Date().timeIntervalSince(start)))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    /// A TCP connection to `host:port` succeeds within `seconds`.
    static func portOpen(host: String, port: UInt16, within seconds: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }
}
