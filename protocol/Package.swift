// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
// Pond's network protocol: what two Ponds, or a Pond and a device paired with it, say to each other and to the
// signaling service. MIT (LICENSE here), unlike the rest of Pond, so anything can speak it: the recorder, the signaling
// service, an app of someone else's. It depends on nothing of Pond's, and nothing here may.
//   Traversal       finding a path through NAT: STUN, ICE's checks, the TURN client (plain Swift, for Linux too)
//   SignalProtocol  the signaling service's messages (plain Swift, for Linux too)
//   PondProtocol    identities, sealed envelopes, pairing, session keys, the encrypted control channel (CryptoKit)
import PackageDescription

var products: [Product] = [
    .library(name: "Traversal", targets: ["Traversal"]),
    .library(name: "SignalProtocol", targets: ["SignalProtocol"]),
]
var targets: [Target] = [
    .target(name: "Traversal"),
    .testTarget(name: "TraversalTests", dependencies: ["Traversal"]),
    .target(name: "SignalProtocol"),
]

#if os(macOS)
products.append(.library(name: "PondProtocol", targets: ["PondProtocol"]))
targets += [
    .target(name: "PondProtocol"),
    .testTarget(name: "PondProtocolTests", dependencies: ["PondProtocol"]),
]
#endif

let package = Package(
    name: "PondProtocol",
    platforms: [.macOS("27.0")],
    products: products,
    targets: targets
)
