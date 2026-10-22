// Why no path was found, in words, and what would fix it. Each side learns a few facts about its own network while
// it looks for a path (whether STUN told it its public address; whether its router shows the world a new port for
// every destination, from asking STUN at two ports; whether it has a global IPv6 address) and sends them to the
// other; with both sides' facts and what the checks saw, the cause can usually be named.
import Foundation
import Traversal

/// What a side knows about its own network.
public struct NetworkFacts: Codable, Equatable, Sendable {
    /// STUN told it its public address.
    public var learnedPublic = false
    /// Its router shows the world a new port for each destination ("symmetric" NAT); nil: not known.
    public var changesPort: Bool?
    /// It has a global (temporary) IPv6 address to offer.
    public var globalIPv6 = false
    /// It's in mesh mode, and whether it has a mesh address there.
    public var mesh = false, meshAddress = false

    public init() {}
}

public enum Diagnosis {
    /// Why no path was found between this Mac and `peer`, and what would fix it.
    public static func explain(mine: NetworkFacts, theirs: NetworkFacts?, report: PathFinder.Report?, peer: String) -> String {
        var causes: [String] = []
        // The mesh: either end without an address in it.
        if mine.mesh && !mine.meshAddress { causes.append("This Mac has no address in the mesh: is Tailscale (or your Headscale client) connected?") }
        if let theirs, theirs.mesh && !theirs.meshAddress { causes.append("\(peer) has no address in the mesh: is its Tailscale (or Headscale client) connected?") }
        if !mine.mesh && !mine.learnedPublic {
            causes.append("This Mac couldn't learn its public address: the signaling server's STUN (UDP 3478) didn't answer. Is it open on the server's firewall?")
        }
        if let theirs, !theirs.mesh, !theirs.learnedPublic {
            causes.append("\(peer) couldn't learn its public address: the signaling server's STUN (UDP 3478) didn't answer it.")
        }
        // The routers.
        switch (mine.changesPort, theirs?.changesPort) {
        case (true, true):
            causes.append("Both ends are behind routers that show the world a new port for every destination (\"symmetric\" NAT): no direct path gets through two of them.")
        case (true, _):
            causes.append("This Mac is behind a router that shows the world a new port for every destination (\"symmetric\" NAT, as on many cellular and office networks), and \(peer)'s router only lets in replies to its own traffic.")
        case (_, true):
            causes.append("\(peer) is behind a router that shows the world a new port for every destination (\"symmetric\" NAT), and this Mac's router only lets in replies to its own traffic.")
        default:
            if let report, report.worked == 0, causes.isEmpty {
                causes.append(report.heardFromPeer
                    ? "\(peer)'s checks reached this Mac, but its answers didn't get back: a firewall on \(peer)'s side is blocking UDP."
                    : "None of \(peer)'s checks reached this Mac: a firewall (on either side, or a network that blocks UDP) is in the way.")
            }
        }
        // IPv6, which needs no address translation.
        let theirIPv6 = theirs?.globalIPv6 ?? false
        if mine.globalIPv6 && theirIPv6 {
            causes.append("Both have IPv6, yet it didn't connect over it: a router's IPv6 firewall is likely blocking incoming UDP.")
        }
        if let report, report.lost { causes.insert("The connection was made, then lost: \(peer) stopped answering.", at: 0) }
        if causes.isEmpty { causes.append("No path between this Mac and \(peer) worked.") }

        var fixes: [String] = []
        if !mine.globalIPv6 { fixes.append("turn on IPv6 at this Mac's router (it needs no address translation)") }
        if theirs != nil, !theirIPv6 { fixes.append("turn on IPv6 at \(peer)'s router") }
        fixes.append("forward a UDP port to the Pond being reached: set remote.port on it (45000, say) and forward that port on its router")
        if !mine.mesh { fixes.append("use a mesh (Tailscale or Headscale) on both, with remote.mesh") }
        fixes.append("run a relay of your own (deploy/, docker compose --profile relay)")
        return causes.joined(separator: " ") + " To fix it: " + fixes.joined(separator: "; ") + "."
    }
}
