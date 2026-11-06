import Foundation
import Testing
@testable import FreeMyMacCore

/// These only ask the guard for a verdict about real-looking paths. Nothing is removed.
@Suite struct SafetyGuardTests {
    let home = NSHomeDirectory()
    var safety: SafetyGuard { SafetyGuard(env: FreeMyMacEnv(home: home, isFixture: false), ownBundle: "/Applications/FreeMyMac.app") }

    @Test(arguments: [
        "/", "/System", "/System/Library/CoreServices", "/usr/bin/ls", "/bin", "/sbin", "/etc/hosts",
        "/private/etc/hosts", "/private/var/db/receipts", "/private/var/vm/swapfile0", "/Library",
        "/Library/LaunchDaemons/x.plist", "/Library/Keychains/System.keychain", "/Applications", "/Users",
        "/Users/someone-else/Documents/a.txt", "/opt/homebrew/bin/brew", "/Volumes/Backup/file", "/nix/store",
        "/Applications/FreeMyMac.app", "/Applications/Foo.app/Contents/Info.plist", "relative/path", "",
    ])
    func refusesSystemLocations(path: String) {
        #expect(!safety.check(path).isAllowed)
    }

    @Test(arguments: [
        "", "/", "/Documents", "/Desktop", "/Downloads", "/Library", "/Pictures", "/Movies", "/.Trash",
        "/Library/Caches", "/Library/Application Support", "/Library/Containers",
        "/Library/Keychains/login.keychain-db", "/.ssh/id_ed25519", "/.gnupg/pubring.kbx", "/.aws/credentials",
        "/Library/Mail/V10", "/Library/Messages/chat.db", "/Library/Safari/History.db",
        "/Pictures/Photos Library.photoslibrary", "/Pictures/Photos Library.photoslibrary/database",
        "/Library/Mobile Documents/com~apple~CloudDocs/a.txt", "/Library/CloudStorage/Dropbox/a.txt",
    ])
    func refusesPersonalLocations(suffix: String) {
        #expect(!safety.check(home + suffix).isAllowed)
    }

    @Test(arguments: [
        "/Documents/report.pdf", "/Downloads/old.dmg", "/Library/Caches/com.example.app",
        "/Library/Application Support/Example", "/Movies/clip.mov",
    ])
    func allowsOrdinaryItems(suffix: String) {
        #expect(safety.check(home + suffix).isAllowed)
    }

    @Test func allowsWholeAppsAndSharedCaches() {
        #expect(safety.check("/Applications/Foo.app").isAllowed)
        #expect(safety.check("/Library/Caches/com.vendor.tool").isAllowed)
    }

    @Test func caseCannotBypassProtection() {
        #expect(!safety.check(home + "/LIBRARY/keychains/login.keychain-db").isAllowed)
        #expect(!safety.check("/SYSTEM/Library").isAllowed)
        #expect(!safety.check(home.uppercased()).isAllowed)
    }

    @Test func dotDotCannotBypassProtection() {
        #expect(!safety.check(home + "/Documents/../Library/Keychains/login.keychain-db").isAllowed)
        #expect(!safety.check(home + "/Documents/..").isAllowed)
        #expect(!safety.check(home + "/Library/Caches/../../.ssh/id_rsa").isAllowed)
        #expect(!safety.check("/Applications/../System/Library").isAllowed)
        #expect(!safety.check("/../../..").isAllowed)
    }

    @Test func dataVolumeSpellingCannotBypassProtection() {
        #expect(!safety.check("/System/Volumes/Data").isAllowed)
        #expect(!safety.check("/System/Volumes/Data" + home).isAllowed)
        #expect(!safety.check("/System/Volumes/Data" + home + "/.ssh/id_rsa").isAllowed)
        #expect(safety.check("/System/Volumes/Data" + home + "/Documents/report.pdf").isAllowed)
    }

    @Test func symlinkedParentCannotBypassProtection() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Keychains/login.keychain-db")
        try FileManager.default.createSymbolicLink(atPath: fixture.path("innocent"), withDestinationPath: fixture.path("Library/Keychains"))
        #expect(!fixture.safety.check(fixture.path("innocent/login.keychain-db")).isAllowed)
        // The link itself is fine to remove, because that leaves its target alone.
        #expect(fixture.safety.check(fixture.path("innocent")).isAllowed)
    }

    @Test func fixtureCannotReachOutsideItself() throws {
        let fixture = try Fixture()
        #expect(!fixture.safety.check(NSHomeDirectory() + "/Documents/report.pdf").isAllowed)
        #expect(!fixture.safety.check("/Applications/Foo.app").isAllowed)
        let inside = try fixture.file("Documents/report.pdf")
        #expect(fixture.safety.check(inside).isAllowed)
    }

    @Test func refusesPathsWhoseParentCannotBeResolved() throws {
        let fixture = try Fixture()
        #expect(!fixture.safety.check(fixture.path("no/such/folder/file.txt")).isAllowed)
    }
}
