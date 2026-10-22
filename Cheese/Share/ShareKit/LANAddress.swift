import Darwin
import Foundation

/// One IPv4 address of a network interface.
struct InterfaceAddress: Equatable, Sendable {
    var interface: String
    var address: String
    var isUp: Bool
    var isLoopback: Bool
}

/// Finds the Mac's address on the local network, the one a phone on the same Wi-Fi can reach.
enum LANAddress {
    /// Tunnels, AirDrop and peer-to-peer links, which a phone on the Wi-Fi can't reach.
    private static let ignoredPrefixes = ["utun", "awdl", "llw", "bridge", "ap", "anpi", "gif", "stf", "ipsec"]

    /// The Mac's LAN address right now, or nil when it isn't on a local network.
    static func current() -> String? {
        best(from: interfaceAddresses())
    }

    /// The best private IPv4 address: Wi-Fi/Ethernet (`en*`) first, `en0` before the others.
    static func best(from addresses: [InterfaceAddress]) -> String? {
        let candidates = addresses.filter { candidate in
            candidate.isUp && !candidate.isLoopback
                && !ignoredPrefixes.contains { candidate.interface.hasPrefix($0) }
                && isPrivateIPv4(candidate.address)
        }
        func rank(_ candidate: InterfaceAddress) -> Int {
            if candidate.interface == "en0" { return 0 }
            return candidate.interface.hasPrefix("en") ? 1 : 2
        }
        return candidates.enumerated()
            .min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?
            .element.address
    }

    /// 10/8, 172.16/12 and 192.168/16. Link-local (169.254) and public addresses don't count.
    static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    private static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(InterfaceAddress(
                interface: String(decoding: nameBytes(entry.ifa_name), as: UTF8.self),
                address: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return result
    }

    private static func nameBytes(_ name: UnsafeMutablePointer<CChar>?) -> [UInt8] {
        guard let name else { return [] }
        return Array(UnsafeBufferPointer(start: name, count: strlen(name))).map { UInt8(bitPattern: $0) }
    }
}
