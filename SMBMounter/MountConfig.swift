import Foundation

/// The technique used to mount a share. This is determined automatically per-share
/// from the mount point location (see `ShareManager.autoMountMethod(forMountPoint:)`)
/// and is never persisted — it is recomputed at mount/unmount time.
enum MountMethod: String, Codable {
    /// AppleScript `mount volume`. macOS mounts the share at /Volumes/<shareName>
    /// and creates that directory itself (with elevation, no user prompt). Used for
    /// any mount point under /Volumes.
    case finder = "finder"

    /// `/sbin/mount_smbfs`. Mounts at an explicit, user-writable path. Used for any
    /// mount point outside /Volumes, so no administrator authorization is ever needed.
    case smbfs  = "smbfs"

    var displayName: String {
        switch self {
        case .finder: return "Finder"
        case .smbfs:  return "Direct (mount_smbfs)"
        }
    }
}
