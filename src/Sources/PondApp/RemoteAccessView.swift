// Settings › Remote Access: reaching this Mac from elsewhere (another Pond, later the iPhone app). On or off and the
// signaling server; the devices paired with it, pairing another (a QR code) or joining another Pond (its code),
// and trying a connection to one; and how connections are made (directly or only over a mesh, a fixed port, this
// Mac's own addresses, a relay of one's own). Saved as changed, and taken up by the recorder at once (only its
// remote access starts again); what it's doing is asked of it every few seconds.
import Devices
import PondCore
import SwiftUI

struct RemoteAccessView: View {
    @Environment(AppModel.self) private var model
    /// What the recorder says (nil: not asked yet, or it isn't running).
    @State private var status: ControlSocket.RemoteStatus?
    @State private var serviceRunning = true
    // The text fields, saved when they're submitted or left.
    @State private var signaling = ""
    @State private var relay = ""
    @State private var port = ""
    /// The mesh's ranges, comma separated (empty: Tailscale's).
    @State private var meshSubnets = ""
    @State private var secret = ""
    @FocusState private var focused: Field?
    @State private var pairing: Pairing?
    @State private var joining = false
    @State private var removing: ControlSocket.RemoteDevice?
    @State private var renaming: ControlSocket.RemoteDevice?
    @State private var newName = ""
    /// A device being tried, and how each try went.
    @State private var testing: String?
    @State private var tested: [String: (ok: Bool, words: String)] = [:]
    @State private var problem: String?

    enum Field { case signaling, relay, port, secret, meshSubnets }

    struct Pairing: Identifiable {
        var code: String
        var expires: Date?
        var id: String { code }
    }

    var remote: Config.Remote { model.config?.remote ?? .init() }

    var body: some View {
        Form {
            Section {
                // (The server as typed saved first: it's what it's turned on with.)
                Toggle(isOn: Binding(get: { remote.enabled }, set: { on in
                    saveFields()
                    save { $0.enabled = on }
                })) {
                    Text("Reach this Mac from elsewhere")
                    Text("From your other Macs running Pond, and later the iPhone app.")
                }
                .disabled(!remote.enabled && signaling.trimmingCharacters(in: .whitespaces).isEmpty)
                LabeledContent("Signaling server") {
                    TextField("Signaling server", text: $signaling, prompt: Text("wss://signal.example.com"))
                        .labelsHidden()
                        .focused($focused, equals: .signaling)
                        .onSubmit(saveFields)
                }
                if remote.enabled { LabeledContent("Status") { statusLabel } }
            } header: {
                Text("Remote access")
            } footer: {
                Text("Paired devices connect to this Mac directly wherever they can, encrypted end to end. The signaling server is your own (see deploy/ in Pond\u{2019}s source): it only passes sealed messages between them, and can read none of them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                let devices = status?.devices ?? []
                if devices.isEmpty {
                    Text(status?.on == true ? "No devices paired yet." : "Turn on remote access to pair devices.").foregroundStyle(.secondary)
                }
                ForEach(devices, id: \.id) { device in deviceRow(device) }
                HStack {
                    Spacer()
                    Button("Join Another Pond\u{2026}") { joining = true }
                    Button("Pair a Device\u{2026}") { pair() }
                }
                .disabled(status?.reachable != true)
            } header: {
                Text("Paired devices")
            } footer: {
                Text("Pair a Device shows a code, good once for ten minutes, for another Mac or device to join with. Join Another Pond pairs this Mac with another, by the code it showed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Connect", selection: Binding(get: { remote.mesh }, set: { mesh in save { $0.mesh = mesh } })) {
                    Text("Directly, over any network").tag(false)
                    Text("Only over my mesh (Tailscale, Headscale)").tag(true)
                }
                if remote.mesh {
                    LabeledContent("Mesh") { meshLabel }
                    LabeledContent("Mesh ranges") {
                        TextField("Mesh ranges", text: $meshSubnets, prompt: Text("Tailscale\u{2019}s"))
                            .labelsHidden()
                            .focused($focused, equals: .meshSubnets)
                            .onSubmit(saveFields)
                    }
                }
                Toggle(isOn: Binding(get: { remote.shareLocalAddresses }, set: { share in save { $0.shareLocalAddresses = share } })) {
                    Text("Offer this Mac\u{2019}s own addresses")
                    Text("Only its temporary IPv6 addresses, never its fixed one. Off, devices on this network meet it through the router.")
                }
                LabeledContent("Fixed UDP port") {
                    TextField("Fixed UDP port", text: $port, prompt: Text("Any"))
                        .labelsHidden()
                        .focused($focused, equals: .port)
                        .onSubmit(saveFields)
                }
                if !remote.mesh {
                    LabeledContent("Relay") {
                        TextField("Relay", text: $relay, prompt: Text("None"))
                            .labelsHidden()
                            .focused($focused, equals: .relay)
                            .onSubmit(saveFields)
                    }
                    if !relay.trimmingCharacters(in: .whitespaces).isEmpty {
                        LabeledContent("Relay secret") {
                            HStack {
                                SecureField("Relay secret", text: $secret,
                                            prompt: Text(status?.relaySecret == true ? "Kept in the Keychain" : "None"))
                                    .labelsHidden()
                                    .focused($focused, equals: .secret)
                                    .onSubmit(saveSecret)
                                Button("Save") { saveSecret() }.disabled(secret.isEmpty)
                            }
                        }
                    }
                }
            } header: {
                Text("Connections")
            } footer: {
                Text(remote.mesh
                    ? "Connections are made over your mesh\u{2019}s tunnel alone: no public address is learned or offered, and no relay is used. Turn it on at both ends. Mesh ranges: Tailscale\u{2019}s (100.64.0.0/10, fd7a:115c:a1e0::/48) unless you give others, comma separated."
                    : "Direct paths are tried first, IPv6 and IPv4. When none works, a fixed port forwarded on your router, or a relay of your own (coturn, in deploy/), gets through; the relay is used only then.")
                    .foregroundStyle(.secondary)
            }
        }
        .pageForm()
        .disabled(!serviceRunning)
        .overlay(alignment: .bottom) {
            if !serviceRunning {
                Text("The recorder isn\u{2019}t running: remote access is kept by it (the doctor\u{2019}s Recorder page).")
                    .font(.callout)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: focused) { old, _ in if old != nil, old != .secret { saveFields() } }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(item: $pairing) { PairingSheet(pairing: $0) }
        .sheet(isPresented: $joining) { JoinSheet { await join($0) } }
        .confirmationDialog("Remove \(removing?.name ?? "this device")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { device in
            Button("Remove", role: .destructive) { Task { await unpair(device) } }
        } message: { _ in
            Text("It can\u{2019}t reach this Mac any more, until it\u{2019}s paired again.")
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let device = renaming { Task { await rename(device, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What it\u{2019}s called on this Mac.")
        }
        .alert("Remote access", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    var statusLabel: some View {
        if let status, status.on, status.reachable {
            Label("Reachable through \(status.signaling ?? "the signaling server")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let why = status?.problem {
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if status?.on == true {
            Label("Connecting to \(status?.signaling ?? "the signaling server")\u{2026}", systemImage: "circle.dotted").foregroundStyle(.secondary)
        } else {
            Label("Starting\u{2026}", systemImage: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func deviceRow(_ device: ControlSocket.RemoteDevice) -> some View {
        let connection = status?.connected.first { $0.device == device.id }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                if let connection {
                    Text("Connected: \(connection.how)").font(.callout).foregroundStyle(.green)
                }
                if let result = tested[device.id] {
                    Text(result.words).font(.callout).foregroundStyle(result.ok ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(testing == device.id ? "Trying\u{2026}" : "Try Connecting") { Task { await test(device) } }
                .disabled(testing != nil)
                .help("Finds a path to it now, and says how (or why not, and what would fix it).")
            Button("Rename\u{2026}") {
                newName = device.name
                renaming = device
            }
            .help("What it\u{2019}s called here: in the toolbar, the camera rail and this list. (It keeps its own name.)")
            Button("Remove\u{2026}") { removing = device }
        }
    }

    // MARK: Saving

    func save(_ change: (inout Config.Remote) -> Void) {
        model.update { config in
            var remote = config.remote ?? .init()
            change(&remote)
            config.remote = remote
        }
    }

    func loadFields() {
        signaling = remote.signaling ?? ""
        relay = remote.relay ?? ""
        port = remote.port.map(String.init) ?? ""
        meshSubnets = (remote.meshSubnets ?? []).joined(separator: ", ")
    }

    /// The text fields saved (those that changed); one that isn't right is put back, the alert saying why.
    /// Whether this Mac is in the mesh now: its address there, or what to check.
    @ViewBuilder var meshLabel: some View {
        switch status?.meshAddresses {
        case let addresses? where !addresses.isEmpty:
            Label("Connected: \(addresses.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case _?:
            Label("This Mac has no address in the mesh. Is Tailscale (or your Headscale client) connected?",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case nil:
            Text("\u{2014}").foregroundStyle(.secondary)
        }
    }

    func saveFields() {
        let trimmed = (signaling: signaling.trimmingCharacters(in: .whitespaces), relay: relay.trimmingCharacters(in: .whitespaces),
                       port: port.trimmingCharacters(in: .whitespaces))
        let fixedPort = UInt16(trimmed.port)
        if !trimmed.port.isEmpty, fixedPort == nil || fixedPort == 0 {
            problem = "The port must be a number from 1 to 65535, or left empty for any."
            port = remote.port.map(String.init) ?? ""
            return
        }
        let ranges = meshSubnets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        save {
            $0.meshSubnets = ranges.isEmpty ? nil : ranges
            $0.signaling = trimmed.signaling.isEmpty ? nil : trimmed.signaling
            $0.relay = trimmed.relay.isEmpty ? nil : trimmed.relay
            $0.port = trimmed.port.isEmpty ? nil : fixedPort
        }
        // (Refused: shown as saved.)
        loadFields()
    }

    func saveSecret() {
        let kept = secret
        secret = ""
        Task {
            var request = ControlSocket.Request(camera: "", action: "remote.relay-secret")
            request.code = kept
            let reply = await model.controlClient.ask(request)
            if let error = reply.error { problem = "The relay\u{2019}s secret wasn\u{2019}t kept: \(error.description)." }
            await refresh()
        }
    }

    // MARK: Asking the recorder

    func refresh() async {
        let reply = await model.controlClient.ask(.init(camera: "", action: "remote.status"), timeout: 5)
        serviceRunning = reply.error != .unreachable
        status = reply.remote
    }

    func pair() {
        Task {
            let reply = await model.controlClient.ask(.init(camera: "", action: "remote.pair"))
            if let code = reply.pairing {
                pairing = Pairing(code: code, expires: reply.pairingExpires)
            } else {
                problem = "No code came: \(reply.error?.description ?? "the recorder didn\u{2019}t answer")."
            }
        }
    }

    /// Paired with another Pond by its code: nil, or why not.
    func join(_ code: String) async -> String? {
        var request = ControlSocket.Request(camera: "", action: "remote.join")
        request.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = await model.controlClient.ask(request, timeout: 45)
        await refresh()
        return reply.error.map { $0.description.prefix(1).uppercased() + $0.description.dropFirst() + "." }
    }

    func rename(_ device: ControlSocket.RemoteDevice, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != device.name else { return }
        var request = ControlSocket.Request(camera: "", action: "remote.rename")
        request.device = device.id
        request.code = name
        let reply = await model.controlClient.ask(request)
        if let error = reply.error { problem = "\(device.name) wasn\u{2019}t renamed: \(error.description)." }
        await refresh()
        model.remoteStatus = status
    }

    func unpair(_ device: ControlSocket.RemoteDevice) async {
        var request = ControlSocket.Request(camera: "", action: "remote.unpair")
        request.device = device.id
        let reply = await model.controlClient.ask(request)
        if let error = reply.error { problem = "\(device.name) wasn\u{2019}t removed: \(error.description)." }
        tested[device.id] = nil
        await refresh()
    }

    func test(_ device: ControlSocket.RemoteDevice) async {
        testing = device.id
        var request = ControlSocket.Request(camera: "", action: "remote.connect")
        request.device = device.id
        let reply = await model.controlClient.ask(request, timeout: 45)
        testing = nil
        if let connection = reply.connection {
            tested[device.id] = (true, connection.prefix(1).uppercased() + connection.dropFirst() + ".")
        } else {
            tested[device.id] = (false, reply.error?.description ?? "It didn\u{2019}t answer.")
        }
    }
}

/// A pairing code: its QR code to scan, and the code itself to paste into another Pond (`pond remote join`).
struct PairingSheet: View {
    let pairing: RemoteAccessView.Pairing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a Device").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                SetupQRCode(payload: pairing.code).frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the other Mac, in Settings › Remote Access, choose **Join Another Pond** and paste this code (or run `pond remote join` with it).")
                        .fixedSize(horizontal: false, vertical: true)
                    if let expires = pairing.expires {
                        Text("Good once, until \(expires.formatted(date: .omitted, time: .shortened)).").foregroundStyle(.secondary)
                    }
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.code, forType: .string)
                    }
                }
            }
            Text(pairing.code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Another Pond's code pasted, and joined.
struct JoinSheet: View {
    let join: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join Another Pond").font(.title2.weight(.semibold))
            Text("Paste the code the other Pond showed (Settings › Remote Access › Pair a Device, or `pond remote pair`).")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code, prompt: Text("pond-pair:\u{2026}"), axis: .vertical)
                .lineLimit(3 ... 5)
                .font(.system(.body, design: .monospaced))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Joining\u{2026}" : "Join") {
                    working = true
                    problem = nil
                    Task {
                        problem = await join(code)
                        working = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !code.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pond-pair:"))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
