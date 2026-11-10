// A camera's sheets and its page: Add Camera, which finds cameras on the network, logs in, checks them and saves;
// the check of a saved camera; and a camera's own settings (its address and login, streams, HomeKit, recording,
// detection and zones, and how Pond talks to it), its Settings tab in the camera window, the one place they're changed.
import Control
import Devices
import PondCore
import SwiftUI
import Watch

/// Runs a check of a saved camera and shows what it found.
/// A check of a saved camera: what is wrong in a word, the details, and a button for the fix.
struct CheckSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: Config.Camera
    /// A result already in hand (a check that just failed): shown, not run again.
    var initial: (lines: [CheckLine], passed: Bool)?
    /// The check to run, if not the saved camera's (a camera's settings check what they would save).
    var runCheck: (() async -> (lines: [CheckLine], passed: Bool))?
    /// Opens the camera's settings, with the cursor in the field to fix.
    let edit: (CameraSettingsPage.Field) -> Void
    @State private var result: (lines: [CheckLine], passed: Bool)?

    /// The problem to act on: the first error, else the first warning that has a fix.
    var problem: CheckLine? {
        result?.lines.first { $0.kind == .error } ?? result?.lines.first { $0.kind == .warning && $0.fix != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                statusIcon.font(.system(size: 34)).frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.title2.bold())
                    Text(advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // The details fill what the sheet has left, scrolling if they need more: the sheet is one size
            // from "Checking…" to the results (a sheet that changed size as they came was drawn wrong).
            GroupBox {
                if let result {
                    ScrollView {
                        CheckLinesView(lines: result.lines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } label: {
                Text("Details").font(.callout.weight(.semibold))
            }
            .frame(maxHeight: .infinity)
            HStack {
                if result != nil {
                    Button { Task { await run() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                }
                Spacer()
                switch problem?.fix {
                case .password?:
                    Button("Enter Password…") { edit(.password) }.keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                case .address?:
                    Button("Change Address…") { edit(.address) }.keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                case .localNetwork?:
                    Button("Open Privacy Settings") { LocalNetworkNote.openSettings() }.keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                default:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
        .task {
            if let initial { result = initial } else { await run() }
        }
    }

    func run() async {
        result = nil
        if let runCheck { result = await runCheck() } else { result = await model.check(camera) }
    }

    @ViewBuilder
    var statusIcon: some View {
        if result == nil {
            ProgressView().controlSize(.regular)
        } else if problem?.kind == .error {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else if problem != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    var headline: String {
        guard result != nil else {
            return model.waitingForLocalNetwork ? "Waiting for permission" : "Checking \(camera.name)…"
        }
        switch problem?.fix {
        case nil: return "\(camera.name) is working"
        case .password?: return model.hasPassword(camera.id) ? "The password was refused" : "No password saved"
        case .address?: return "\(camera.name) can\u{2019}t be reached"
        case .privacyMode?: return "Privacy mode is on"
        case .busy?: return "No video from \(camera.name)"
        case .cameraSettings?: return "Works, with a setting to change"
        case .localNetwork?: return "Pond can\u{2019}t reach your network"
        case .unexplained?: return "\(camera.name) didn\u{2019}t work"
        }
    }

    /// Where the camera's own settings are changed, in its brand's words if known.
    var cameraApp: String { camera.device?.appName ?? "the camera\u{2019}s own app" }

    var advice: String {
        guard result != nil else {
            return model.waitingForLocalNetwork ? LocalNetworkNote.waiting : "Logging in, then watching the video for 6 seconds."
        }
        switch problem?.fix {
        case nil: return "It logs in and sends video as it should."
        case .password?:
            return model.hasPassword(camera.id)
                ? "The camera turned down \(camera.username) and the saved password. Enter the password you use in \(cameraApp)."
                : "Enter the camera's password; it is kept in your Keychain."
        case .address?:
            return "Nothing answered at \(camera.host). Check that the camera is on and on your network; if its address changed, give it a fixed one in your router and enter it here."
        case .privacyMode?:
            return "The camera hides its picture. Turn privacy mode off in \(cameraApp), then try again."
        case .busy?:
            return "The camera connected but sent no video. Many cameras send video to only a few apps at once: if others are watching it (another NVR, \(cameraApp)), close one and try again."
        case .cameraSettings?:
            return "Recording works. For HomeKit, change the setting below in \(cameraApp)."
        case .localNetwork?:
            return "macOS has not allowed Pond to find devices on your local network. Turn Pond on in Privacy & Security › Local Network, then try again."
        case .unexplained?:
            return problem?.text ?? "Pond couldn\u{2019}t tell why. Try again."
        }
    }
}

struct AddCameraSheet: View {
    /// The sheet's margin: its heading, its cards (a grouped form's own inset) and its buttons, one distance from its edges.
    static let margin = 20.0
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// At most this tall (the window's height); the form scrolls inside.
    var height = 560.0
    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false
    @State private var host = ""
    @State private var username = "admin"
    @State private var password = ""
    @State private var checking = false
    @State private var result: (lines: [CheckLine], passed: Bool)?
    @State private var added = false
    /// Add Camera lists the ignored cameras on the network too, when asked.
    @State private var showingIgnored = false
    /// Name has the keyboard as the sheet opens (not the first camera found on the network).
    @FocusState private var nameFocused: Bool
    @State private var kind = Config.Camera.Kind.camera
    /// What the camera said it is, during the check.
    @State private var device: Config.Device?
    /// The optional last step: nil until chosen, then whether the camera goes in the Home app.
    @State private var homeKitChosen: Bool?
    /// With it, whether it records to HomeKit Secure Video (as a camera's settings have it; on by default here).
    @State private var homeKitRecording = true
    /// What the camera does to the storage, from the rate the check measured.
    @State private var impact: StorageOutlook.Impact?
    /// The stream addresses: typed in, or asked of the camera when checking (and where they came from).
    @State private var mainURL = ""
    @State private var subURL = ""
    @State private var streamsFrom: String?
    @State private var showStreams = false

    var camera: Config.Camera {
        var c = Config.Camera.reolink(id: id, name: name.isEmpty ? id : name, host: host.trimmingCharacters(in: .whitespaces),
                                      username: username)
        if !mainURL.isEmpty { c.main = mainURL.trimmingCharacters(in: .whitespaces) }
        if !subURL.isEmpty { c.sub = subURL.trimmingCharacters(in: .whitespaces) }
        c.kind = kind
        c.device = device
        return c
    }

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the camera a name." }
        if !Config.isSlug(id) { return "The ID must be lowercase letters, digits and dashes, starting with a letter." }
        if model.config?.cameras.contains(where: { $0.id == id }) == true { return "There is already a camera \(id)." }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the camera's address." }
        if username.isEmpty { return "Give the username." }
        if password.isEmpty { return "Give the password." }
        if [mainURL, subURL].contains(where: { !$0.isEmpty && !StreamAddressField.isValid($0) }) {
            return StreamAddressField.problem
        }
        return nil
    }

    /// The sheet's pages, one after another: the camera's details; the check (and, passed, the camera added, with
    /// what it does to the storage); then the Home app's offer, a page of its own, so Skip plainly leaves the
    /// camera added, only not in HomeKit.
    enum Page: Int { case details, check, homeKit }
    @State private var page = Page.details
    /// Which way the pages slide: on (forward) or back.
    @State private var forward = true

    func go(_ next: Page) {
        forward = next.rawValue > page.rawValue
        withAnimation(.smooth(duration: 0.35)) { page = next }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page == .homeKit ? "Add to the Home App" : "Add Camera").font(.title2.bold())
                .padding([.top, .horizontal], Self.margin)
                .contentTransition(.opacity)
            ZStack {
                switch page {
                case .details: detailsPage.transition(slide)
                case .check: checkPage.transition(slide)
                case .homeKit: homeKitPage.transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Its buttons' edges in line with the cards' and the heading's.
            bar.padding(Self.margin)
        }
        .frame(width: 520, height: min(height, 560))
        .onAppear {
            if let from = model.addingFrom {
                use(from)
                model.addingFrom = nil
            }
        }
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
        .task { await model.findCameras() }
    }

    /// In from the side it's going towards, out the other.
    var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: Pages

    var detailsPage: some View {
        Form {
            foundSection
            // Headed, as each section is, so it's set apart from the cameras on the network above it.
            Section("Camera") {
                TextField("Name", text: $name, prompt: Text("Front porch"))
                    .focused($nameFocused)
                    .onChange(of: name) { if !idEdited { id = slug(name) } }
                // Each note under its own row's label.
                LabeledContent {
                    TextField("ID", text: Binding(get: { id }, set: { id = $0; idEdited = true }), prompt: Text("front-porch"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                } label: {
                    Text("ID")
                    Text("Names the camera\u{2019}s folders and its HomeKit accessory; best not changed later.")
                }
                TextField("Address", text: $host, prompt: Text("192.168.1.30"))
                LabeledContent {
                    KindPicker(kind: $kind)
                } label: {
                    Text("Type")
                    Text("A doorbell is recognised when it says so, and can be marked here.")
                }
            }
            Section("Login") {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            Section {
                FoldRow(title: "Stream addresses", summary: streamSummary, expanded: $showStreams)
                if showStreams {
                    Group {
                        StreamAddressField(title: "Main stream", note: StreamAddressField.mainNote, address: $mainURL,
                                           prompt: "Asked of the camera")
                        StreamAddressField(title: "Sub-stream", note: StreamAddressField.subNote, address: $subURL,
                                           prompt: "Asked of the camera")
                    }
                    .padding(.leading, FoldRow.indent)
                }
            }
        }
        .formStyle(.grouped)
        // On the sheet's own background, as its heading and buttons are (the form's own made it a band of another
        // shade between them).
        .scrollContentBackground(.hidden)
    }

    /// The check as it goes (in view from the start), then what it found: added, or why not yet.
    var checkPage: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Group {
                        if checking {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: added ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(added ? .green : .orange)
                        }
                    }
                    .font(.largeTitle)
                    .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(checkHeadline).font(.headline)
                        Text(checkDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .animation(.smooth(duration: 0.25), value: checking)
                if let device {
                    LabeledContent("Device", value: [device.manufacturer, device.model].filter { !$0.isEmpty }.joined(separator: " "))
                        .transition(.opacity)
                }
            }
            if let result {
                Section("What the check found") { CheckLinesView(lines: result.lines) }
                    .transition(.opacity)
            }
            if let impact { StorageImpactSection(impact: impact, name: camera.name) }
        }
        .formStyle(.grouped)
        // On the sheet's own background, as its heading and buttons are (the form's own made it a band of another
        // shade between them).
        .scrollContentBackground(.hidden)
        .animation(.smooth(duration: 0.3), value: result?.lines.count)
        .animation(.smooth(duration: 0.3), value: device)
    }

    var checkHeadline: String {
        if checking { return "Checking \(camera.name)\u{2026}" }
        if added { return "\(camera.name) added" }
        if result?.passed == true, impact?.fits == false { return "\(camera.name) won\u{2019}t fit in the days kept" }
        return "\(camera.name) didn\u{2019}t pass the check"
    }

    var checkDetail: String {
        if checking {
            if model.waitingForLocalNetwork { return LocalNetworkNote.waiting }
            return checkingStep
        }
        if added { return "Recording now. Its controls and details are filled in as it\u{2019}s set up." }
        if result?.passed == true { return "Add it anyway, or make room in Settings \u{203A} Storage first." }
        return "Go back to change its details, or add it anyway."
    }

    /// The offer to put it in the Home app, a page of its own (it's added already), then its pairing.
    var homeKitPage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            if homeKitChosen == nil {
                VStack(spacing: 16) {
                Image(systemName: "homekit")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("Put \(camera.name) in the Home app?").font(.title3.bold())
                Text("It then shows in the Home app on your iPhone, iPad and Mac\(kind == .doorbell ? ", and rings there when its button is pressed" : ""). Pond\u{2019}s background service serves it. \(camera.name) is added either way; you can do this later in its settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                Toggle("Record to HomeKit Secure Video", isOn: $homeKitRecording)
                    .toggleStyle(.checkbox)
                    .help("Clips of what it notices, kept in iCloud (needs a home hub and iCloud+); set what it records in the Home app")
                    .padding(.top, 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                AddedToHome(cameraID: camera.id, recording: homeKitRecording)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity)
    }

    /// Each page's buttons.
    @ViewBuilder
    var bar: some View {
        HStack {
            switch page {
            case .details:
                if let problem, !name.isEmpty || !host.isEmpty {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Check and Add") {
                    go(.check)
                    Task { await checkAndAdd() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            case .check:
                if !added {
                    Button("Back") { go(.details) }.disabled(checking)
                }
                Spacer()
                if added {
                    Button("Continue") { go(.homeKit) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let result, !checking, !result.passed || impact?.fits == false {
                        Button("Add Anyway") { save() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .homeKit:
                Spacer()
                if homeKitChosen == nil {
                    Button("Skip") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Add to the Home App") { addToHome() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Cameras on the network that aren't set up: picking one fills in its address and a name. Looked for
    /// again as the sheet opens (shown by the header, so the form keeps its height). Ignored ones only when
    /// asked for.
    @ViewBuilder
    var foundSection: some View {
        let ignored = model.ignoredFound
        let found = showingIgnored ? model.camerasNotSetUp : model.newCameras
        if !added, !found.isEmpty || !ignored.isEmpty {
            Section {
                ForEach(found) { camera in
                    Button { use(camera) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: host == camera.host ? "checkmark.circle.fill" : "video")
                                .foregroundStyle(host == camera.host ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(camera.suggestedName.isEmpty ? camera.host : camera.suggestedName)
                                Text(camera.detail)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isIgnored(camera) { Text("Ignored").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !ignored.isEmpty {
                    Button(showingIgnored ? "Hide Ignored" : ignored.count == 1 ? "Show 1 Ignored" : "Show \(ignored.count) Ignored") {
                        withAnimation(.snappy(duration: 0.25)) { showingIgnored.toggle() }
                    }
                    // Quiet: secondary, and not where the keyboard starts.
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("On your network")
                    if model.findingCameras {
                        ProgressView().controlSize(.mini)
                            .help("Looking on your network\u{2026}")
                    }
                }
            }
            .disabled(checking)
        }
    }

    func use(_ camera: FoundCamera) {
        host = camera.host
        if name.isEmpty || !idEdited { name = camera.suggestedName }
    }

    var streamSummary: String {
        if let streamsFrom { return "From \(streamsFrom)" }
        return mainURL.isEmpty && subURL.isEmpty ? "Asked of the camera" : "Typed in"
    }

    /// What the check is doing now, in words.
    @State private var checkingStep = "Looking for its streams\u{2026}"

    func checkAndAdd() async {
        checking = true
        result = nil
        device = nil
        impact = nil
        checkingStep = "Looking for its streams\u{2026}"
        // The stream addresses, unless typed in: asked of the camera (its make's, or ONVIF's); else Reolink's.
        if mainURL.isEmpty, subURL.isEmpty,
           let found = await model.findStreams(host: camera.host, username: username, password: password) {
            mainURL = found.main
            subURL = found.sub
            streamsFrom = found.from
        }
        checkingStep = "Logging in, then watching the video for 6 seconds\u{2026}"
        let r = await model.check(camera, password: password, seconds: 6)
        if r.passed {
            checkingStep = "Asking what it is\u{2026}"
            // Reached: ask what it is (model, serial, doorbell), for HomeKit and the settings.
            device = await model.identify(host: camera.host, username: username, password: password)
            if device?.isDoorbell == true { kind = .doorbell }
        }
        // What it does to the storage, at the rate just measured; a camera that pushes the recordings past
        // the days kept waits for Add Anyway.
        impact = r.passed ? await model.storageImpact(ofAdding: camera.id, megabitsPerSecond: checkedRate) : nil
        withAnimation(.smooth(duration: 0.3)) {
            checking = false
            result = r
        }
        if r.passed, impact?.fits != false { save() }
    }

    /// The video rate the check measured, in Mbit/s.
    var checkedRate: Double? {
        let rate = AppDefaults.store.double(forKey: AppModel.checkedRateKey(camera.id))
        return rate > 0 ? rate : nil
    }

    func addToHome() {
        withAnimation(.smooth(duration: 0.35)) { homeKitChosen = true }
        model.setHomeKit(camera.id, true, recording: homeKitRecording)
    }

    func save() {
        if model.add(camera, password: password) {
            withAnimation(.smooth(duration: 0.3)) { added = true }
        }
    }
}

/// One camera's settings, its Settings tab in the camera window (the one place they're changed). The privacy switch
/// and HomeKit act at once; everything else is applied by Save: the details, a new password (after it has been
/// checked against the camera), and a new id. Save says what it's doing, then that it's saved, and why not if not,
/// here on the page.
struct CameraSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: Config.Camera
    /// As the panel over the main window (from wherever the camera is: CameraSettingsPanel), not the Settings window's
    /// page: its everyday settings only (what it is, HomeKit, recording, detection and zones), its name over them,
    /// Cancel, and Save closing it; the rest (login, streams, device, what it's learnt, removing it) behind All
    /// Settings….
    var panel = false
    @FocusState private var focused: Field?
    enum Field { case password, address }
    @State private var name = ""
    @State private var host = ""
    /// How Pond talks to the camera ("reolink", "onvif"), as it would be saved.
    @State private var provider = ""
    /// The stream addresses, as they would be saved.
    @State private var mainURL = ""
    @State private var subURL = ""
    @State private var username = ""
    @State private var newID = ""
    @State private var password = ""
    @State private var showAdvanced = false
    @State private var showDevice = false
    @State private var showLogin = false
    /// The connection check, as a sheet over this one: what it starts from if a check already ran (a new
    /// password that didn't work, on Save).
    @State private var showingCheck = false
    @State private var checkResult: (lines: [CheckLine], passed: Bool)?
    @State private var confirmRemove = false
    @State private var kind = Config.Camera.Kind.camera
    @State private var homeKitViewers = Config.Camera.defaultHomeKitViewers
    @State private var instantLive = false
    @State private var homeKitVideo = Config.Camera.HomeKitVideo.camera
    @State private var homeKitRecording = false
    @State private var detection = true
    @State private var recordsSub = false
    @State private var homeKitMotion = Config.Camera.HomeKitMotion.detection
    @State private var showHomeKitOptions = false
    @State private var zones: [Config.Zone] = []
    @State private var editingZones = false
    /// What's been said of its events (this wasn't anything, it was something), and forgetting it, confirming.
    @State private var feedback: [EventFeedback] = []
    @State private var confirmForgetFeedback = false
    @State private var confirmForget = false
    @State private var identifying = false
    /// The camera's recordings, for the remove prompt.
    @State private var recordingsSize: Int64?
    /// While Save works (a new password is checked against the camera first, which takes a few seconds).
    @State private var saving = false
    /// Saved, until the next change: said beside Save.
    @State private var justSaved = false
    /// Why Save didn't save, said here (not in another window).
    @State private var saveError: String?

    /// The camera as it would be saved, for checking.
    var edited: Config.Camera {
        var c = camera
        c.username = username
        c.main = mainURL.trimmingCharacters(in: .whitespaces)
        c.sub = subURL.trimmingCharacters(in: .whitespaces)
        return c
    }

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the camera a name." }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the camera's address." }
        if username.isEmpty { return "Give the username." }
        if ![mainURL, subURL].allSatisfy(StreamAddressField.isValid) { return StreamAddressField.problem }
        if newID != camera.id, !Config.isSlug(newID) {
            return "The ID must be lowercase letters, digits and dashes, starting with a letter."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // Most used first: name and address, HomeKit, then the login (rarely changed after
                // setup), what the camera is, and the advanced.
                Section {
                    TextField("Name", text: $name)
                    TextField("Address", text: $host, prompt: Text("192.168.1.30"))
                        .focused($focused, equals: .address)
                    // At once, like HomeKit (not on Save).
                    Toggle(isOn: Binding(get: { model.isPrivate(camera.id) },
                                         set: { on in Task { await model.setPrivacy(camera.id, on) } })) {
                        Text("Private")
                        Text(model.isPrivateOnCameraOnly(camera.id)
                             ? "Its own privacy mode is on: turn it off in \(camera.device?.appName ?? "the camera\u{2019}s own app"). Pond shows it as private meanwhile."
                             : "Not recorded, shown live or in the Home app until you turn this off. The Home app shows it as off meanwhile.")
                    }
                    .disabled(model.isPrivateOnCameraOnly(camera.id))
                } header: {
                    header
                }

                homeKitSection

                recordingSection

                detectionSection

                if !panel { moreSection }
            }
            .pageForm()

            footer
        }
        .frame(width: panel ? 600 : nil, height: panel ? 640 : nil)
        .frame(maxWidth: panel ? nil : .infinity, maxHeight: panel ? nil : .infinity)
        // A new address for the camera moves the stream addresses with it (those on its old address).
        .onChange(of: host) { old, new in
            func moved(_ url: String) -> String {
                guard var parts = URLComponents(string: url), parts.host == old.trimmingCharacters(in: .whitespaces) else { return url }
                parts.host = new.trimmingCharacters(in: .whitespaces)
                return parts.string ?? url
            }
            mainURL = moved(mainURL)
            subURL = moved(subURL)
        }
        .onAppear {
            load()
            takeFocus()
        }
        // Sent here to fix something (a check's Enter Password… on the Doctor tab): the cursor where the fix goes.
        .onChange(of: model.cameraSettingsFocus) { takeFocus() }
        // A change after saving: no longer just saved.
        .onChange(of: changed) { if changed { justSaved = false } }
        .alert("Not saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("Remove \(camera.name) from the Home app?", isPresented: $confirmForget) {
            Button("Remove from HomeKit", role: .destructive) {
                model.forgetHomeKit(camera.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pond forgets this camera\u{2019}s HomeKit pairing. Remove it in the Home app as well (the accessory\u{2019}s settings › Remove Accessory). Added again later, it gets a new setup code.")
        }
        .sheet(isPresented: $editingZones) {
            ZoneEditorSheet(camera: saved, zones: $zones)
        }
        .sheet(isPresented: $showingCheck) {
            CheckSheet(camera: edited, initial: checkResult, runCheck: { await check() }) { field in
                // Back to these settings, with the cursor where the fix goes.
                showingCheck = false
                if field == .password { showLogin = true }
                Task {
                    try? await Task.sleep(for: .seconds(0.35))
                    focused = field
                }
            }
        }
        .confirmationDialog("Remove \(camera.name)?", isPresented: $confirmRemove) {
            Button("Remove Camera", role: .destructive) {
                model.remove(camera.id)
                finish(removed: true)
            }
            Button("Remove Camera and Recordings", role: .destructive) {
                model.remove(camera.id, deleteRecordings: true)
                finish(removed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
        // Measured when the sheet opens: a prompt's text is not updated once it is showing.
        .task { recordingsSize = await model.recordingsSize(of: camera.id) }
    }

    /// The fields as the camera is saved (on opening, and Revert).
    func load() {
        let camera = saved
        name = camera.name
        host = camera.host
        mainURL = camera.main
        subURL = camera.sub
        provider = camera.device?.provider ?? ""
        username = camera.username
        password = ""
        newID = camera.id
        kind = camera.kind
        homeKitViewers = camera.homeKitViewerSlots
        instantLive = camera.keepsLiveReady
        homeKitVideo = camera.homekitVideo ?? .camera
        homeKitRecording = camera.homekitRecording == true
        detection = camera.watches
        recordsSub = camera.recordsSub == true
        homeKitMotion = camera.homekitMotion ?? .detection
        zones = camera.zones
    }

    /// The field asked for (model.cameraSettingsFocus), with the cursor in it: the login opened for the password.
    func takeFocus() {
        guard let field = model.cameraSettingsFocus else { return }
        model.cameraSettingsFocus = nil
        if field == .password { showLogin = true }
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            focused = field
        }
    }

    /// Done with it: the page stays, as saved (or, removed, goes to all cameras).
    func finish(removed: Bool = false) {
        if panel { dismiss() } else if removed { model.settingsPage = .cameras } else { load() }
    }

    /// Whether anything Save applies differs from what's saved.
    var changed: Bool {
        let c = saved
        return name != c.name || host != c.host || mainURL != c.main || subURL != c.sub || username != c.username
            || !password.isEmpty || newID != c.id || provider != (c.device?.provider ?? "") || kind != c.kind
            || homeKitViewers != c.homeKitViewerSlots || instantLive != c.keepsLiveReady
            || homeKitVideo != (c.homekitVideo ?? .camera) || homeKitRecording != (c.homekitRecording == true)
            || detection != c.watches || recordsSub != (c.recordsSub == true)
            || homeKitMotion != (c.homekitMotion ?? .detection) || zones != c.zones
    }

    /// The camera as saved now (HomeKit changes apply on Save).
    var saved: Config.Camera { model.config?.cameras.first { $0.id == camera.id } ?? camera }

    /// HomeKit acts at once (adding starts the service and shows the code); only the type waits for Save.
    @ViewBuilder
    var homeKitSection: some View {
        Section {
            if saved.homekit, let state = model.homeKitState(for: saved), state == .ready || state == .live {
                // All well: one row, like "Not in the Home app" (the name is the sheet's title, so a long one
                // cannot push this onto two lines).
                HStack(spacing: 12) {
                    Label("In the Home app", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove from HomeKit\u{2026}", role: .destructive) { confirmForget = true }
                }
            } else if saved.homekit {
                HomeKitPairing(cameraID: camera.id).padding(.vertical, 2)
                Button("Remove from HomeKit\u{2026}", role: .destructive) { confirmForget = true }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not in the Home app")
                        Text("Starts Pond\u{2019}s background service, then shows the setup code.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Add to the Home App\u{2026}") { model.setHomeKit(camera.id, true) }
                        .help("If the service is running, it restarts: recording pauses for a few seconds.")
                }
            }
            if saved.homekit {
                // Video only with its motion from the camera: nothing would start a recording. The choice is kept,
                // shown, and comes back (with Pond's detection, it records).
                let paused = provider == Config.Device.videoOnly && !motionFromDetection
                Toggle(isOn: $homeKitRecording) {
                    Text("Allow recording in the Home app")
                    if paused {
                        let others = CameraProviders.choices(for: saved.device).map(\.name).joined(separator: " or ")
                        Text("Paused while \(saved.name) is video only and its motion is its own: recording needs motion. Choose Pond\u{2019}s detection in Options, or \(others.isEmpty ? "another way" : others) again.")
                    } else {
                        Text("HomeKit Secure Video: your home hub records \(saved.name)\u{2019}s motion to iCloud, where the Home app keeps it. Needs a home hub and iCloud+. Then turn recording on in the Home app, in \(saved.name)\u{2019}s Recording Options.")
                    }
                }
                .disabled(paused)
                if !paused, homeKitRecording, saved.homekitRecording == true, let status = model.homeKitRecording(for: saved) {
                    RecordingSummary(text: RecordingText(status, camera: saved, in: .settings))
                }
                // The rest, set once and rarely again: folded away.
                FoldRow(title: "Options", summary: homeKitOptionsSummary, expanded: $showHomeKitOptions)
                if showHomeKitOptions {
                    Group {
                        homeKitPicture
                        homeKitMotionRow
                        Picker(selection: $homeKitViewers) {
                            ForEach(Array(Config.Camera.homeKitViewerRange), id: \.self) { Text("\($0)").tag($0) }
                        } label: {
                            Text("Home app viewers at once")
                            Text("Each iPhone, iPad, Mac or Apple TV watching \(saved.name) live in the Home app takes one; one more is told the camera is busy. They share one connection to the camera; Pond\u{2019}s own windows don\u{2019}t count.")
                        }
                    }
                    .padding(.leading, FoldRow.indent)
                }
            }
        } header: {
            Text("HomeKit")
        }
    }

    /// HomeKit's options, closed: "Camera's stream · Pond's detection".
    var homeKitOptionsSummary: String {
        let picture = homeKitVideo == .camera ? "Camera\u{2019}s stream" : "Re-encoded"
        let motion = motionFromDetection ? "Pond\u{2019}s detection" : "Camera\u{2019}s motion"
        return "\(picture) \u{00B7} \(motion)"
    }

    /// Its motion in the Home app (what HomeKit Secure Video records on, and notifies about) follows Pond's detection.
    var motionFromDetection: Bool { detection && homeKitMotion == .detection }

    /// What sets the camera's motion in the Home app: Pond's detection, or the camera's own motion.
    var homeKitMotionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Motion in the Home app")
            Picker("Motion in the Home app", selection: $homeKitMotion) {
                Text("Pond\u{2019}s detection").tag(Config.Camera.HomeKitMotion.detection)
                Text("The camera\u{2019}s own").tag(Config.Camera.HomeKitMotion.camera)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!detection)
            Text(!detection ? "The camera\u{2019}s own: Pond isn\u{2019}t watching \(saved.name) (Detection, below)."
                 : homeKitMotion == .detection
                 ? "Only a person, vehicle, bike or animal in \(saved.name)\u{2019}s zones: the Home app records and notifies for those, not for leaves, shadows or headlights."
                 : "Whatever the camera calls motion. Pond\u{2019}s detection still makes its events here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// The picture the Home app gets: the camera's own stream, or one Pond makes, with what each costs.
    var homeKitPicture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Picture in the Home app")
            Picker("Picture in the Home app", selection: $homeKitVideo) {
                Text("As the camera sends it").tag(Config.Camera.HomeKitVideo.camera)
                Text("Re-encoded by Pond").tag(Config.Camera.HomeKitVideo.reencoded)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(homeKitPictureNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Where the camera's own settings are changed, in its brand's words if known.
    var cameraApp: String { saved.device?.appName ?? "the camera\u{2019}s own app" }

    var homeKitPictureNote: String {
        switch homeKitVideo {
        case .camera:
            // In the brand's own words when the camera's provider has them; otherwise in general terms.
            let named = CameraProviders.provider(saved.device?.provider)?.subStreamName.map { " (called \u{201C}\($0)\u{201D} there)" } ?? ""
            return "The Home app gets the camera\u{2019}s lighter stream, as the camera makes it: no work for this Mac. If it looks grainy, raise that stream\u{2019}s resolution or bitrate in \(cameraApp)\(named)."
        case .reencoded:
            return "Pond makes the Home app\u{2019}s picture from the camera\u{2019}s full-quality stream, sized for each iPhone, iPad or Mac: sharp at home, and kept light enough to play smoothly away from home. Uses this Mac\u{2019}s video hardware for each viewer, and the picture arrives about a tenth of a second later."
        }
    }

    /// What the camera is, in one line for the collapsed header: "Reolink E1 Pro · Doorbell".
    var deviceSummary: String {
        let device = saved.device.map { [$0.manufacturer, $0.model].filter { !$0.isEmpty }.joined(separator: " ") }
        let via = CameraProviders.provider(saved.device?.provider).map { "via \($0.name)" }
        return [device, kind == .doorbell ? "Doorbell" : "Camera", via].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// How Pond talks to the camera, said plainly, as a switch: its make's own way (when Pond has one), ONVIF,
    /// or its video only (no logins for its details or events).
    @ViewBuilder
    func providerRow(_ device: Config.Device) -> some View {
        let choices = CameraProviders.choices(for: device)
        let changed = provider != (device.provider ?? "")
        // Laid out by hand: the name and the switch on one line, the note under both, the row's whole width
        // (LabeledContent would put a switch this wide under its note, or squeeze the note beside it).
        // Room between the switch and the note under it, which would otherwise touch.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Talks through")
                Spacer(minLength: 0)
                Picker("Talks through", selection: $provider) {
                    ForEach(choices, id: \.id) { Text($0.name).tag($0.id) }
                    Text("Video only").tag(Config.Device.videoOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            providerNote(changed: changed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func providerNote(changed: Bool) -> some View {
        Group {
            if changed, provider == Config.Device.videoOnly {
                Text("Saving stops Pond reading its motion\(kind == .doorbell ? " and button" : "").")
            } else if changed, let name = CameraProviders.provider(provider)?.name {
                Text("Saving asks the camera through \(name) first\(saved.homekit ? ", then restarts Pond\u{2019}s background service" : "").")
            } else if provider == Config.Device.videoOnly {
                Text("Pond logs in only for its video; its motion\(kind == .doorbell ? " and button" : "") aren\u{2019}t watched.")
            } else {
                Text("For its details, motion\(kind == .doorbell ? " and doorbell button" : "").")
            }
        }
    }

    /// Why a video-only camera can't be asked again: asking is logging in, through one of the other ways.
    var askNeedsLogin: String {
        let ways = CameraProviders.choices(for: saved.device).map(\.name).joined(separator: " or ")
        return "Asking again needs \(ways.isEmpty ? "another way than video only" : ways) above."
    }

    /// A camera that never said what it is: its video is all Pond has.
    var videoOnlyRow: some View {
        LabeledContent {
            Text("Video only")
        } label: {
            Text("Talks through")
            Text("Pond records and shows it, but can\u{2019}t read its details or motion. Turning on ONVIF in the camera\u{2019}s own app may change that; then Ask Again.")
        }
    }

    /// The rarely changed, as rows of one card that open in place (like System Settings' "Advanced…"): the
    /// login, what the camera is (with its type), and the advanced (its ID and stream addresses). Closed,
    /// each says what is inside; the whole row opens and closes it.
    @ViewBuilder
    var moreSection: some View {
        Section {
            FoldRow(title: "Login", summary: username == camera.username && password.isEmpty ? camera.username : "Changed",
                    expanded: $showLogin)
            if showLogin {
                Group {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password, prompt: Text("Unchanged"))
                        .focused($focused, equals: .password)
                }
                .padding(.leading, FoldRow.indent)
            }

            FoldRow(title: "Device", summary: deviceSummary, expanded: $showDevice)
            if showDevice {
                Group {
                    LabeledContent {
                        KindPicker(kind: $kind)
                    } label: {
                        Text("Type")
                        if saved.device?.isDoorbell == true, kind == .camera {
                            Text("The camera says it is a doorbell.")
                        } else if kind != saved.kind, saved.homekit {
                            Text("Saving restarts Pond\u{2019}s background service, pausing recording for a few seconds.")
                        } else {
                            Text("A doorbell rings in the Home app when its button is pressed.")
                        }
                    }
                    if let device = saved.device {
                        LabeledContent("Maker", value: device.manufacturer.isEmpty ? "Not given" : device.manufacturer)
                        LabeledContent("Model", value: device.model)
                        LabeledContent("Serial number") {
                            Text(device.serial ?? "Not given").textSelection(.enabled)
                        }
                        LabeledContent("Firmware", value: device.firmware ?? "Not given")
                        providerRow(device)
                    } else if identifying {
                        Text("Asking the camera\u{2026}").foregroundStyle(.secondary)
                    } else {
                        videoOnlyRow
                    }
                    LabeledContent {
                        Button(identifying ? "Asking\u{2026}" : "Ask Again") {
                            identifying = true
                            Task {
                                await model.identify(camera.id)
                                identifying = false
                                if saved.device?.isDoorbell == true { kind = .doorbell }
                            }
                        }
                        // Asking means logging in, which video only doesn't: it says so beside the button and on it.
                        .disabled(identifying || provider == Config.Device.videoOnly)
                        .help(provider == Config.Device.videoOnly ? askNeedsLogin : "")
                    } label: {
                        Text(provider == Config.Device.videoOnly ? "As the camera last reported it. \(askNeedsLogin)"
                             : "As the camera reports it; HomeKit shows the same.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, FoldRow.indent)
            }

            FoldRow(title: "Advanced", expanded: $showAdvanced)
            if showAdvanced {
                Group {
                    // Each setting's note under its own label, next to what it explains.
                    LabeledContent {
                        // As wide as an id needs, so the note beside it gets the rest of the row.
                        TextField("Camera ID", text: $newID)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 160)
                    } label: {
                        Text("Camera ID")
                        Text("Names the camera\u{2019}s folders, its Keychain item and its HomeKit accessory. Changing it moves the password; recordings already made keep the old folder.")
                    }
                    StreamAddressField(title: "Main stream", note: StreamAddressField.mainNote, address: $mainURL)
                    StreamAddressField(title: "Sub-stream", note: StreamAddressField.subNote, address: $subURL)
                    Toggle(isOn: $instantLive) {
                        Text("Start live view instantly")
                        Text("Keeps the sub-stream open, so live views in the Home app and Pond, and snapshots, start at once instead of after a few seconds. Costs one more connection to the camera and about 0.3 Mbit/s on your network. On by default for a camera in HomeKit.")
                    }
                }
                .padding(.leading, FoldRow.indent)
            }
        } header: {
            // A header like HomeKit's, so the space above both cards is the same.
            Text("More")
        }
    }

    /// Which of its streams is recorded.
    var recordingSection: some View {
        Section {
            Picker(selection: $recordsSub) {
                Text("Main stream").tag(false)
                Text("Sub-stream").tag(true)
            } label: {
                Text("Record")
                Text(recordsSub
                     ? "Less sharp, and a fraction of the room: for a camera that doesn\u{2019}t need its full resolution kept. Live view and the Home app still use the main stream."
                     : "Its sharpest picture, as it sends it.")
            }
            .disabled(subURL.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Recording")
        }
    }

    var detectionSection: some View {
        Section {
            Toggle(isOn: $detection) {
                Text("Watch for people, vehicles and animals")
                Text("Pond looks at the sub-stream while something moves and makes events of what it sees, on this Mac.")
            }
            LabeledContent {
                Button("Edit Zones\u{2026}") { editingZones = true }
                    .disabled(!detection)
            } label: {
                Text("Zones")
                Text(zonesSummary)
            }
            // What it's learnt from what was said of its events, and forgetting it.
            if !feedback.isEmpty {
                LabeledContent {
                    Button("Forget\u{2026}") { confirmForgetFeedback = true }
                } label: {
                    Text("Learnt from your feedback")
                    Text(feedbackSummary)
                }
            }
        } header: {
            Text("Detection")
        }
        .task(id: camera.id) {
            let source = EventSource(config: model.config), id = camera.id
            feedback = await Task.detached { source?.feedback(camera: id) ?? [] }.value
        }
        .confirmationDialog("Forget what \(camera.name) has learnt?", isPresented: $confirmForgetFeedback) {
            Button("Forget", role: .destructive) {
                model.forgetFeedback(camera: camera.id)
                feedback = []
            }
        } message: {
            Text("Events you said weren\u{2019}t anything, or were, are forgotten, and none are quieted for being like them.")
        }
    }

    /// What's been said, and the rules learnt from it.
    var feedbackSummary: String {
        let dismissed = feedback.count { $0.verdict == .nothing }, confirmed = feedback.count - dismissed
        let rules = EventJudge(feedback: feedback).rules.map(\.words)
        let said = [dismissed > 0 ? "\(dismissed) you said weren\u{2019}t anything" : nil,
                    confirmed > 0 ? "\(confirmed) you said were something" : nil].compactMap { $0 }.joined(separator: ", ")
        return ([said.prefix(1).uppercased() + said.dropFirst() + "."] + rules.map { "Quieting: \($0)." }).joined(separator: " ")
    }

    var zonesSummary: String {
        let watched = zones.filter { !$0.isIgnored }.count, ignored = zones.count - watched
        if zones.isEmpty { return "None: everything in the picture counts." }
        let parts = [watched > 0 ? "\(watched) watched" : nil, ignored > 0 ? "\(ignored) ignored" : nil].compactMap { $0 }
        return parts.joined(separator: ", ") + (watched > 0 ? ": events come only from what\u{2019}s in a watched zone." : ".")
    }

    var removeMessage: String {
        let size = recordingsSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
        return "Its settings and password are removed. Its recordings, events and their pictures (\(size)) can stay until retention deletes them, or be deleted now, which cannot be undone."
    }

    /// The first section's heading, in line with the form's headings as the Doctor tab's is (DoctorView.header): who
    /// it logs in as, and where (the window's title names it). Checking it is the Doctor tab's (Run Check…); Save
    /// checks a new password itself.
    var header: some View {
        HStack {
            if panel {
                // (No window's title over the panel: its name here.)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? camera.name : name).font(.title2.bold()).foregroundStyle(.primary)
                    Text("\(camera.id) · \(camera.username)@\(camera.host)").foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.bottom, 6)
            } else {
                Text("\(camera.id) · \(camera.username)@\(camera.host)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // Held but unseen, as the Doctor tab's buttons are tall: the first card starts where it does there, so
            // switching tabs nothing moves.
            Button("Run Check\u{2026}") {}.font(.body).hidden().accessibilityHidden(true)
        }
        .controlSize(.small)
        .textCase(nil)
    }

    var footer: some View {
        HStack {
            if panel {
                // The rest of its settings, and its doctor, in the Settings window (what's changed here not kept).
                Button("All Settings\u{2026}") {
                    dismiss()
                    model.showCamera(camera.id, tab: .settings)
                }
                .help("All of \(camera.name)\u{2019}s settings, and its doctor, in the Settings window")
            } else {
                // Apart from Save and Revert, so it is not pressed by mistake.
                Button("Remove Camera…", role: .destructive) { confirmRemove = true }
                    .foregroundStyle(.red)
            }
            Spacer()
            if saving {
                ProgressView().controlSize(.small)
                Text(password.isEmpty ? "Saving\u{2026}" : "Checking the password\u{2026}")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if justSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if panel {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Revert") { load() }
                    .disabled(!changed || saving)
            }
            Button("Save") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || !changed || saving)
        }
        // Its buttons' edges in line with the cards' above.
        .besideForm()
        .padding(.vertical, 16)
    }

    /// Logs in with the new password if one is typed, the saved one otherwise, at the address and username as
    /// they would be saved.
    func check() async -> (lines: [CheckLine], passed: Bool) {
        guard !password.isEmpty || model.hasPassword(camera.id) else {
            return ([CheckLine(.error, "There is no password for \(camera.name) in the Keychain. Type it above.", fix: .password)], false)
        }
        // A typed password is tried here; the saved one, by pond (only pond reads saved passwords).
        let result = password.isEmpty ? await model.check(edited) : await model.check(edited, password: password, seconds: 0)
        // Reached: also ask what it is, if it has not said yet.
        if result.passed, saved.device == nil, password.isEmpty { await model.identify(camera.id) }
        return result
    }

    /// Applies the changes, then says it's saved, or why not (what the model would have said in the main window,
    /// said here instead).
    func save() async {
        saving = true
        let ok = await apply()
        saving = false
        if let alert = model.alert {
            model.alert = nil
            saveError = alert
        } else if ok {
            justSaved = true
        }
    }

    /// Applies the changes; false where one couldn't be (the model's alert says why, or the check sheet).
    func apply() async -> Bool {
        if !password.isEmpty {
            // A new password is tried before it is kept; if it doesn't work, the check says why.
            let result = await check()
            guard result.passed else {
                checkResult = result
                showingCheck = true
                return false
            }
        }
        guard model.edit(camera.id, name: name.trimmingCharacters(in: .whitespaces),
                         host: host.trimmingCharacters(in: .whitespaces), username: username,
                         main: edited.main, sub: edited.sub) else { return false }
        if !password.isEmpty, !model.setPassword(password, for: camera.id) { return false }
        if kind != saved.kind { model.setKind(camera.id, kind) }
        if homeKitViewers != saved.homeKitViewerSlots { model.setHomeKitViewers(camera.id, homeKitViewers) }
        if instantLive != saved.keepsLiveReady { model.setInstantLive(camera.id, instantLive) }
        if homeKitVideo != (saved.homekitVideo ?? .camera) { model.setHomeKitVideo(camera.id, homeKitVideo) }
        if homeKitRecording != (saved.homekitRecording == true) { model.setHomeKitRecording(camera.id, homeKitRecording) }
        if recordsSub != (saved.recordsSub == true) { model.setRecordsSub(camera.id, recordsSub) }
        if detection != saved.watches || zones != saved.zones { model.setDetection(camera.id, detection, zones: zones) }
        if homeKitMotion != (saved.homekitMotion ?? .detection) { model.setHomeKitMotion(camera.id, homeKitMotion) }
        // The new way of talking to it, if it answers that way; else it stays as it was, and says so.
        if provider == Config.Device.videoOnly, !saved.isVideoOnly {
            model.setVideoOnly(camera.id)
        } else if !provider.isEmpty, provider != (saved.device?.provider ?? ""), let chosen = CameraProviders.provider(provider) {
            if await !model.setProvider(camera.id, provider) {
                let current = CameraProviders.provider(saved.device?.provider)?.name ?? "its current way"
                model.alert = "\(camera.name) didn\u{2019}t answer through \(chosen.name), so Pond still talks to it through \(current)."
                provider = saved.device?.provider ?? ""
                return false
            }
        }
        if newID != camera.id {
            guard model.rename(camera.id, to: newID) else { return false }
            // Renamed on its page: the page follows it.
            model.settingsPage = .camera(newID)
        }
        finish()
        return true
    }
}

/// While macOS asks whether Pond may reach the local network.
enum LocalNetworkNote {
    static let waiting = "Waiting for you to allow Pond to find devices on your local network (macOS is asking)."

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}


/// A row that opens and closes the rows under it: a chevron, the title, and while closed a summary of what
/// is inside. The whole row is the button.
struct FoldRow: View {
    /// How far the rows it opens are set in, under its title.
    static let indent = 20.0

    let title: String
    var summary: String?
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                Spacer()
                if let summary, !expanded {
                    Text(summary).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "open" : "closed")
    }
}

/// In Add Camera: what the new camera does to the storage. The drive as it will be with it (its share of the
/// recording a part of its own), what it adds a day, and whether the days kept still fit.
struct StorageImpactSection: View {
    let impact: StorageOutlook.Impact
    let name: String

    var body: some View {
        let after = impact.after
        let days = StorageEstimate.duration(days: after.continuousDays)
        Section {
            StorageBar(segments: StorageBar.segments(drive: impact.drive, used: impact.used, estimate: after,
                                                     keepDays: impact.keepDays, reserveGB: impact.reserveGB,
                                                     newCamera: (name, impact.camera.rate)))
                .padding(.vertical, 4)
            LabeledContent("\(name) adds", value: "\(StorageEstimate.size(impact.perDay)) a day")
            if impact.fits {
                CheckRow(ok: true, title: "Holds the \(impact.keepDays) days you keep",
                         detail: "With \(name), \(impact.drive.name) holds about \(days) of continuous recording.")
            } else if impact.fittedBefore {
                CheckRow(ok: false, title: "With \(name), \(impact.drive.name) holds about \(days) of the \(impact.keepDays) days you keep",
                         detail: "The oldest recording of every camera would be deleted sooner to make room. Add it anyway, or keep fewer days (Retention), or use a bigger drive (Storage).")
            } else {
                CheckRow(ok: false, title: "\(impact.drive.name) already holds fewer than the \(impact.keepDays) days you keep",
                         detail: "With \(name), about \(days). A bigger drive (Storage), or fewer days (Retention), would match.")
            }
        } header: {
            Text("Space on \(impact.drive.name)")
        } footer: {
            if impact.camera.source == .assumed {
                Text("The check didn\u{2019}t measure the video, so this assumes a typical camera.").foregroundStyle(.secondary)
            }
        }
    }
}

/// A camera or a doorbell: the two kinds HomeKit has, side by side, at their own width at the row's end.
struct KindPicker: View {
    @Binding var kind: Config.Camera.Kind

    var body: some View {
        Picker("Type", selection: $kind) {
            Text("Camera").tag(Config.Camera.Kind.camera)
            Text("Doorbell").tag(Config.Camera.Kind.doorbell)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

/// A stream address: shown in its row (shortened in the middle if long), typed in or corrected in a popover
/// wide enough for a whole one, with what the stream is used for under its name.
struct StreamAddressField: View {
    let title: String
    let note: String
    @Binding var address: String
    /// What the row says while there is no address.
    var prompt = "None"
    @State private var editing = false

    static let mainNote = "Recorded, and used for large tiles and HomeKit Secure Video."
    static let subNote = "Used for small tiles, snapshots and the Home app\u{2019}s live view."
    static let problem = "A stream address starts with rtsp:// and has no login in it."

    /// An rtsp:// address without a login (the password is kept in the Keychain).
    static func isValid(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        // (Or a demo camera's: its scheme of its own, made-up streams the demo draws.)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "rtsp" || scheme == Demo.scheme, parts.host?.isEmpty == false
        else { return false }
        return parts.user == nil && parts.password == nil
    }

    // As the Type and ID rows look: the name with its note wrapping under it on the left, the address and its
    // button on the right at the name's line. Laid out here rather than by LabeledContent, which stacks the
    // right side under a long note.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(address.isEmpty ? prompt : address)
                .font(address.isEmpty ? .body : .system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .trailing)
                .help(address)
            Button("Edit\u{2026}") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField(title, text: $address, prompt: Text("rtsp://"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { editing = false }
            Text(!address.isEmpty && !Self.isValid(address) ? Self.problem : note)
                .font(.subheadline)
                .foregroundStyle(!address.isEmpty && !Self.isValid(address) ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { editing = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

/// Add Camera's HomeKit page once asked: the code to scan, large and centred as the offer before it, while the
/// Home app hasn't the camera; then that it's there (and what's next); what's wrong, if anything, as the
/// camera's settings say it.
struct AddedToHome: View {
    @Environment(AppModel.self) private var model
    let cameraID: String
    let recording: Bool

    /// How tall the code's digits stand (the font's cap height), for its placeholder.
    static let codeDigitHeight: CGFloat = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize,
                                                                      weight: .semibold).capHeight

    var camera: Config.Camera? { model.config?.cameras.first { $0.id == cameraID } }

    var body: some View {
        if let camera, let state = model.homeKitState(for: camera) {
            Group {
                switch state {
                case .ready, .live:
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: state)
                        Text("\(camera.name) is in the Home app").font(.title3.bold())
                        Text(recording
                             ? "It records to HomeKit Secure Video: choose what it records in the Home app, in its settings \u{203A} Recording Options."
                             : "Find it in the Home app on your iPhone, iPad and Mac.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 400)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .notAdded, .waitingForService:
                    let setup = model.homeKitSetup(for: camera)
                    VStack(spacing: 12) {
                        Text("Scan with the Home app").font(.title3.bold())
                        // The code's place kept from the start (a tile, then the code in it), so nothing moves
                        // when the service has made it: it comes up where it'll stay.
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.quaternary.opacity(setup == nil ? 0.6 : 0))
                                .overlay { if setup == nil { ProgressView().controlSize(.small) } }
                            if let setup {
                                SetupQRCode(payload: setup.uri)
                                    .padding(6)
                                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94))
                                                                .combined(with: .blur), removal: .opacity))
                            }
                        }
                        .frame(width: 168, height: 168)
                        // Until then, a bar as wide as the code and as tall as its digits, where they'll be.
                        Text(setup?.code ?? "000-00-000")
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .opacity(setup == nil ? 0 : 1)
                            .overlay {
                                if setup == nil {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(.quaternary)
                                        .frame(height: Self.codeDigitHeight)
                                        .transition(.opacity)
                                }
                            }
                            .textSelection(.enabled)
                        
                        Text("In the Home app, choose **+ \u{203A} Add Accessory** and scan the code (or enter it). Then choose **Add Anyway**: Pond isn\u{2019}t certified by Apple, which the Home app mentions.")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 400)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(state == .notAdded ? "Waiting for the Home app\u{2026}" : "Starting HomeKit\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .animation(.spring(duration: 0.55, bounce: 0.15), value: setup?.code)
                    .transition(.opacity)
                default:
                    HomeKitPairing(cameraID: cameraID).frame(maxWidth: 440)
                }
            }
            .animation(.smooth(duration: 0.35), value: state)
        }
    }
}

extension AnyTransition {
    /// Out of focus to sharp (or back).
    static var blur: AnyTransition { .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0)) }
}

struct BlurModifier: ViewModifier {
    let radius: Double
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
