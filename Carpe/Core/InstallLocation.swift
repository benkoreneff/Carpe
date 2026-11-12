import Foundation

/// Where a copy of the app sits, as far as moving it to Applications goes.
enum InstallLocation {
    static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// True for a bundle in `applications` or in a folder inside it.
    static func isInstalled(_ bundle: URL, in applications: URL = applications) -> Bool {
        let folder = applications.standardizedFileURL.path
        return bundle.standardizedFileURL.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Gatekeeper runs a downloaded app that was opened where it landed (in a
    /// disk image, or unpacked in Downloads) from a random read-only path. The
    /// copy the user sees is somewhere else and can't be found from here.
    static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.standardizedFileURL.path.contains("/AppTranslocation/")
    }
}
