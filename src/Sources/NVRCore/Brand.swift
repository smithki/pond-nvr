// The product's names, in one place: what it is called, the command, and the names it leaves on the Mac
// (the Keychain items, folders and the login service). `Legacy` holds what it was called before (nvr), for
// `pond migrate` to carry an existing setup over.
import Foundation

public enum Brand {
    /// The product, as people see it.
    public static let name = "Pond"
    /// The command, which is also the login service's program and the only reader of the Keychain items.
    public static let command = "pond"
    /// Reverse-DNS prefix, from the product's domain (pond.camera).
    public static let identifier = "camera.pond"

    /// Keychain services: camera passwords (account: the camera's ID), and each camera's HomeKit record.
    public static let keychainService = "pond"
    public static let homeKitKeychainService = "pond-homekit"
    /// Remote access: this Mac's own keys, and the devices paired with it.
    public static let remoteKeychainService = "pond-remote"

    /// The folder for the settings file, the HomeKit status and the app's socket to the service.
    public static let supportFolder = "~/Library/Application Support/Pond"
    /// The login service's log folder and file names.
    public static let logFolder = "~/Library/Logs/Pond"
    public static let logName = "pond.log"
    public static let outputLogName = "pond-output.log"
    /// The login service's launchd label.
    public static let serviceLabel = "camera.pond.recorder"
    /// The marker that makes a folder a storage folder.
    public static let storageMarker = ".pond-storage"
    /// Environment variables for development: another settings file, pictures of the app, made-up events.
    public static let configVariable = "POND_CONFIG"

    /// What the product was called before: an existing setup is moved from these by `pond migrate`.
    public enum Legacy {
        public static let keychainService = "nvr"
        public static let homeKitKeychainService = "nvr-homekit"
        public static let supportFolder = "~/Library/Application Support/nvr"
        public static let logFolder = "~/Library/Logs/nvr"
        public static let logName = "nvr.log"
        public static let outputLogName = "nvr-output.log"
        public static let serviceLabel = "com.local.nvr"
        public static let storageMarker = ".nvr-storage"
        /// The log's source for the recorder itself, in lines written before.
        public static let logSource = "nvr"
    }
}
