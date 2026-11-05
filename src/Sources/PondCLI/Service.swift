import PondCore
import Recorder

/// Runs the recorder; tests replace it.
public protocol ServiceRunning {
    func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog)
}

public struct RealService: ServiceRunning {
    public init() {}

    public func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog) {
        RecordingService(config: config, passwords: passwords, log: log).run(for: seconds)
    }
}
