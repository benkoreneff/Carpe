import Foundation
import Testing

/// Whether a copy of the app counts as installed, and whether its real
/// location is known.
@Suite struct InstallLocationTests {
    static func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test func aCopyInApplicationsIsInstalled() {
        #expect(InstallLocation.isInstalled(Self.url("/Applications/Carpe.app")))
        #expect(InstallLocation.isInstalled(Self.url("/Applications/Utilities/Carpe.app")))
        #expect(InstallLocation.isInstalled(Self.url("/Applications/../Applications/Carpe.app")))
    }

    @Test func copiesElsewhereAreNot() {
        for path in [
            "/Volumes/Carpe/Carpe.app",
            "/Users/someone/Downloads/Carpe.app",
            "/Users/someone/Applications/Carpe.app",
            "/Users/someone/Projects/Carpe/build.noindex/release/Build/Products/Release/Carpe.app",
            // Not inside the folder, only named like it.
            "/Applications2/Carpe.app",
            "/ApplicationsOld/Carpe.app",
        ] {
            #expect(!InstallLocation.isInstalled(Self.url(path)), "\(path)")
        }
    }

    @Test func anotherFolderCanStandInForApplications() {
        let folder = Self.url("/tmp/Apps")
        #expect(InstallLocation.isInstalled(Self.url("/tmp/Apps/Carpe.app"), in: folder))
        #expect(!InstallLocation.isInstalled(Self.url("/Applications/Carpe.app"), in: folder))
    }

    @Test func gatekeepersRandomPathIsRecognised() {
        #expect(InstallLocation.isTranslocated(
            Self.url("/private/var/folders/ab/xyz/T/AppTranslocation/6C0F1B2A-1111-2222-3333-444455556666/d/Carpe.app")
        ))
        #expect(!InstallLocation.isTranslocated(Self.url("/Volumes/Carpe/Carpe.app")))
        #expect(!InstallLocation.isTranslocated(Self.url("/Users/someone/Downloads/Carpe.app")))
    }
}
