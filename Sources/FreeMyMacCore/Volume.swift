import Foundation

public struct VolumeInfo: Sendable, Equatable {
    public let total: Int64
    public let free: Int64
    /// Used on the Data volume alone. The remainder of `total - free` belongs
    /// to macOS's own volumes (System, Preboot, Recovery, VM), which can't be
    /// cleaned from here.
    public let dataUsed: Int64

    public init(total: Int64, free: Int64, dataUsed: Int64) {
        self.total = total
        self.free = free
        self.dataUsed = dataUsed
    }

    public var used: Int64 { total - free }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current() -> VolumeInfo? {
        var info = statfs()
        guard statfs(FreeMyMacEnv.dataVolume, &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        let total = Int64(info.f_blocks) * block
        let free = Int64(info.f_bavail) * block
        return VolumeInfo(total: total, free: free, dataUsed: spaceUsed(FreeMyMacEnv.dataVolume) ?? (total - free))
    }

    /// On APFS, volumes share one pool of space, so statfs can only describe the
    /// whole container. This is the per-volume figure `df` reports.
    private static func spaceUsed(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(0x8000_0000 | 0x0080_0000) // ATTR_VOL_INFO | ATTR_VOL_SPACEUSED
        var buffer = [UInt8](repeating: 0, count: 16)
        guard getattrlist(path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        // The reply is a 4-byte length followed by the value, packed with no padding.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}

public struct StorageSegment: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case files, apps, appData, developer, system, hidden, macOS, free
    }

    public let kind: Kind
    public let size: Int64
    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .files: return "Your files"
        case .apps: return "Apps"
        case .appData: return "App data and caches"
        case .developer: return "Developer tools"
        case .system: return "Shared system data"
        case .hidden: return "Hidden from FreeMyMac"
        case .macOS: return "macOS"
        case .free: return "Free"
        }
    }
}

public enum StorageBreakdown {
    /// Splits the whole disk into segments that always add up to `volume.total`.
    /// Anything the scan couldn't read shows up as `.hidden` instead of vanishing.
    public static func segments(volume: VolumeInfo, root: FileNode?, env: FreeMyMacEnv) -> [StorageSegment] {
        let macOS = max(0, volume.used - volume.dataUsed)
        guard let root else {
            return [
                StorageSegment(kind: .hidden, size: volume.dataUsed),
                StorageSegment(kind: .macOS, size: macOS),
                StorageSegment(kind: .free, size: volume.free),
            ]
        }

        var sizes: [StorageSegment.Kind: Int64] = [:]
        func add(_ kind: StorageSegment.Kind, _ size: Int64) { sizes[kind, default: 0] += size }

        var accounted: Int64 = 0
        if !env.isFixture {
            for child in root.children where child.name.lowercased() != "users" {
                accounted += child.size
                switch child.name.lowercased() {
                case "applications": add(.apps, child.size)
                case "opt", "nix", "usr": add(.developer, child.size)
                default: add(.system, child.size)
                }
            }
        }
        if let home = root.node(at: env.home) {
            for child in home.children {
                let name = child.name
                accounted += child.size
                if name.lowercased() == "library" {
                    add(.appData, child.size)
                } else if name.lowercased() == "applications" {
                    add(.apps, child.size)
                } else if name.hasPrefix(".") || ["go", "orbstack"].contains(name.lowercased()) {
                    add(.developer, child.size)
                } else {
                    add(.files, child.size)
                }
            }
        }
        // Everything too small to list individually, plus other users' folders.
        add(.system, max(0, root.size - accounted))

        let scanned = sizes.values.reduce(0, +)
        let hidden = max(0, volume.dataUsed - scanned)
        if volume.dataUsed < scanned, let overflow = sizes[.system] {
            // Clones and hard links can make a scan exceed what APFS reports.
            sizes[.system] = max(0, overflow - (scanned - volume.dataUsed))
        }

        var segments = [StorageSegment.Kind.files, .apps, .appData, .developer, .system].compactMap { kind -> StorageSegment? in
            guard let size = sizes[kind], size > 0 else { return nil }
            return StorageSegment(kind: kind, size: size)
        }
        if hidden > 0 { segments.append(StorageSegment(kind: .hidden, size: hidden)) }
        segments.append(StorageSegment(kind: .macOS, size: macOS))
        segments.append(StorageSegment(kind: .free, size: volume.free))
        return segments
    }
}

public enum Permissions {
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// macOS has no API for this, so it tries to open places only Full Disk
    /// Access can reach. Reading a directory listing is all it does.
    public static func hasFullDiskAccess(env: FreeMyMacEnv) -> Bool {
        if env.isFixture { return true }
        for probe in ["Library/Application Support/com.apple.TCC", "Library/Safari", "Library/Mail", ".Trash"] {
            let fd = open(env.inHome(probe), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }
}
