// What a camera says it is (maker, model, serial number, firmware, doorbell or not), from whichever
// provider recognises it first. Nil if none does: the camera still works, it just goes without these details.
import Foundation
import PondCore

public enum DeviceReader {
    public static func read(host: String, username: String, password: String,
                            providers: [CameraProvider] = CameraProviders.all) async -> Config.Device? {
        for provider in providers {
            if let device = await provider.identify(host: host, username: username, password: password) { return device }
        }
        return nil
    }
}
