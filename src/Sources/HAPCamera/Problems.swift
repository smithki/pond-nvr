// Failures as problem kinds for the status the app shows: only those whose cause is certain get a name;
// everything else is `.other`, and its details stay in the log.
import Ingest
import PondCore

extension HomeKitStatus.Problem.Kind {
    init(_ error: RTSPError) {
        switch error {
        case .transport(.unreachable), .transport(.refused): self = .cameraUnreachable
        case .unauthorized: self = .loginRefused
        case .timeout: self = .noAnswer
        default: self = .other
        }
    }
}
