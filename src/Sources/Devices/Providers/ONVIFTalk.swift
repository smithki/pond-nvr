// Talking back over ONVIF: the RTSP backchannel on the camera's main stream (Ingest's Backchannel), offered
// when the camera has an audio output and its RTSP describes a track to send on.
import Foundation
import Ingest
import NVRCore

final class ONVIFTalk: TalkControl {
    let access: CameraAccess
    let stream: String
    let abilities = Config.Controls.Talk(provider: "onvif")

    init(access: CameraAccess, stream: String) {
        self.access = access
        self.stream = stream
    }

    func open() async throws(ControlFailure) -> TalkSession {
        let (access, stream) = (access, stream)
        let result = await Task.detached { () -> Result<Backchannel, RTSPError> in
            do throws(RTSPError) {
                return .success(try Backchannel(url: stream, username: access.username, password: access.password))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(channel): return BackchannelSession(channel)
        case .failure(.notFound): throw .notSupported
        case .failure(.unauthorized): throw .loginRefused
        case .failure(.transport), .failure(.timeout): throw .unreachable
        case let .failure(error): throw .failed(error.description)
        }
    }
}

final class BackchannelSession: TalkSession, @unchecked Sendable {
    let channel: Backchannel
    var sampleRate: Double { channel.sampleRate }

    init(_ channel: Backchannel) { self.channel = channel }

    func send(_ samples: [Int16]) throws(ControlFailure) {
        do throws(RTSPError) {
            try channel.send(samples)
        } catch {
            throw .unreachable
        }
    }

    func close() { channel.close() }
}

extension ONVIFProvider {
    public func talk(_ access: CameraAccess) async -> Offer<any TalkControl> {
        guard let stream = access.mainStream else { return .no }
        guard let device = await CameraSessions.shared.onvif(access) else { return .unknown }
        guard let media = device.services[ONVIF.media],
              let outputs = try? await device.client.call(media, "<GetAudioOutputs xmlns=\"\(ONVIF.media)\"/>"),
              outputs.first("AudioOutputs") != nil else { return .no }
        let offered = await Task.detached {
            Backchannel.offered(url: stream, username: access.username, password: access.password)
        }.value
        guard offered != nil else { return .no }
        return .yes(ONVIFTalk(access: access, stream: stream))
    }
}
