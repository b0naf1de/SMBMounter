import SwiftUI

struct ShareRowView: View {
    @Binding var share: SMBShare
    @EnvironmentObject var manager: ShareManager

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(share.name)
                    .font(.headline)

                Text(share.smbURL)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let error = share.lastError, share.status == .error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if let date = share.lastConnected, share.status == .mounted {
                    Text("Connected since \(date.formatted(.dateTime.hour().minute()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(share.status.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusBackground)
                .cornerRadius(10)

            Button {
                if manager.isMounted(share) {
                    manager.unmount(share)
                } else {
                    manager.mount(share)
                }
            } label: {
                Image(systemName: manager.isMounted(share) ? "eject.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(manager.isMounted(share) ? .orange : .accentColor)
            }
            .buttonStyle(.plain)
            .help(manager.isMounted(share) ? "Disconnect" : "Connect")
            .disabled(share.status == .connecting)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    var statusIcon: some View {
        if share.autoMount {
            autoMountStatusIcon
        } else {
            baseStatusIcon
        }
    }

    /// Standard icon for shares not configured for auto-mount.
    @ViewBuilder
    var baseStatusIcon: some View {
        switch share.status {
        case .mounted:
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .foregroundColor(.green)
        case .disconnected:
            Image(systemName: "externaldrive.badge.minus")
                .foregroundColor(.secondary)
        case .connecting:
            ProgressView()
                .scaleEffect(0.6)
        case .error:
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.red)
        }
    }

    /// Same icon set but with a circular-arrow overlay to indicate the share is
    /// configured for auto-mount (recurring/repeat behaviour).
    @ViewBuilder
    var autoMountStatusIcon: some View {
        switch share.status {
        case .mounted:
            autoMountIcon("externaldrive.fill.badge.checkmark", color: .green)
        case .disconnected:
            autoMountIcon("externaldrive.badge.minus", color: .secondary)
        case .connecting:
            ZStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor.opacity(0.4))
                ProgressView()
                    .scaleEffect(0.5)
            }
        case .error:
            autoMountIcon("externaldrive.badge.exclamationmark", color: .red)
        }
    }

    private func autoMountIcon(_ name: String, color: Color) -> some View {
        ZStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18))
                .foregroundColor(color.opacity(0.4))
            Image(systemName: name)
                .font(.system(size: 10))
                .foregroundColor(color)
        }
    }

    var statusBackground: Color {
        switch share.status {
        case .mounted: return Color.green.opacity(0.15)
        case .disconnected: return Color.secondary.opacity(0.1)
        case .connecting: return Color.yellow.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }
}
