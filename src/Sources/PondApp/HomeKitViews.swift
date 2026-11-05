// HomeKit in the app: a badge on each live tile of a camera that is in HomeKit (none for the others), its
// popover with what is going on and what to do, the setup code with its QR code, and the HomeKit section of
// a camera's settings.
import CoreImage
import CoreImage.CIFilterBuiltins
import PondCore
import SwiftUI

/// On a tile: the HomeKit symbol, accented while someone watches in the Home app, with a warning mark when
/// something needs doing. Click for the details.
struct HomeKitBadge: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let state: HomeKitState
    var compact = false
    var height: Double
    @State private var open = false
    @Environment(\.openSettings) private var openSettingsWindow

    var body: some View {
        let text = HomeKitText(state, camera: camera)
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "homekit")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state == .live ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .overlay(alignment: .topTrailing) {
                        if state.needsAttention {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: compact ? 8 : 10, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .orange)
                                .offset(x: 5, y: -4)
                        }
                    }
                if state == .live, !compact {
                    Text("Live").font(.callout.weight(.semibold))
                }
            }
            .font(compact ? .callout : .headline)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(text.title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HomeKitDetails(text: text, recording: model.homeKitRecording(for: camera).map { RecordingText($0, camera: camera) }) { action in
                open = false
                perform(action)
            }
        }
    }

    func perform(_ action: HomeKitText.Action) {
        switch action {
        case .startService: model.applyHomeKitChange()
        case .cameraSettings:
            model.settingsTab = .cameras
            model.cameraToEdit = camera.id
            openSettingsWindow()
        case .showLog: HomeKitText.openLog()
        }
    }
}

/// What the badge's popover says: the state, why, and buttons for what to do.
struct HomeKitDetails: View {
    let text: HomeKitText
    /// HomeKit Secure Video, for a camera Pond offers to it.
    var recording: RecordingText?
    let perform: (HomeKitText.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text.title, systemImage: "homekit").font(.headline)
            Text(text.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let recording {
                Divider()
                RecordingSummary(text: recording)
            }
            if !text.actions.isEmpty {
                HStack {
                    Spacer()
                    ForEach(Array(text.actions.enumerated()), id: \.offset) { i, action in
                        if i == 0 {
                            Button(action.label) { perform(action) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(action.label) { perform(action) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// The Home app's QR code for a setup payload ("X-HM://…"), drawn sharp at any size.
struct SetupQRCode: View {
    let payload: String

    var body: some View {
        if let image = Self.image(payload) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    static func image(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// The setup code as the Home app shows it (123-45-678), with the QR code to scan.
struct HomeKitSetupCode: View {
    let code: String
    let payload: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SetupQRCode(payload: payload).frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("In the Home app, choose **+ › Add Accessory** and scan this code, or enter:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text("Then choose **Add Anyway**: Pond isn\u{2019}t certified by Apple, which the Home app mentions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Adding a camera to the Home app, as it goes: the setup code and QR code while the Home app has not added
/// it yet, then "in the Home app"; or what is wrong, with what to do. Used by Add Camera's last step and
/// the camera's settings.
struct HomeKitPairing: View {
    @Environment(AppModel.self) private var model
    let cameraID: String

    var camera: Config.Camera? { model.config?.cameras.first { $0.id == cameraID } }

    var body: some View {
        if let camera, let state = model.homeKitState(for: camera) {
            VStack(alignment: .leading, spacing: 10) {
                switch state {
                case .ready, .live:
                    Label("\(camera.name) is in the Home app", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                case .notAdded, .waitingForService:
                    if let setup = model.homeKitSetup(for: camera) { HomeKitSetupCode(code: setup.code, payload: setup.uri) }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state == .notAdded ? "Waiting for the Home app\u{2026}" : "Starting HomeKit\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                default:
                    let text = HomeKitText(state, camera: camera, in: .settings)
                    Label(text.title, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    Text(text.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if text.actions.contains(.startService) {
                        Button("Start Service") { model.applyHomeKitChange() }
                    } else if text.actions.contains(.showLog) {
                        Button("Show Log") { HomeKitText.openLog() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// HomeKit Secure Video in two lines: the state (orange when it needs attention) and what to know.
struct RecordingSummary: View {
    let text: RecordingText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text.title, systemImage: text.attention ? "exclamationmark.circle.fill" : "record.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(text.attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            Text(text.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
