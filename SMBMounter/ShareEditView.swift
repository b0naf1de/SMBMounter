import SwiftUI

enum EditMode {
    case add
    case edit(SMBShare)
    case clone(SMBShare)
}

struct ShareEditView: View {
    let mode: EditMode
    let onSave: (SMBShare, String) -> Void

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var manager: ShareManager

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var mountPoint: String = ""
    @State private var autoMount: Bool = true
    @State private var showPassword: Bool = false
    @State private var hasLoaded = false

    var title: String {
        switch mode {
        case .add:   return "Add Share"
        case .edit:  return "Edit Share"
        case .clone: return "Clone Share"
        }
    }

    /// The mount point that will actually resolve (mirrors SMBShare.resolvedMountPoint).
    var resolvedMountPoint: String {
        mountPoint.isEmpty ? "/Volumes/\(shareName.isEmpty ? "ShareName" : shareName)" : mountPoint
    }

    /// True when the current mount point matches an existing share's mount point.
    /// When editing, the share's own entry is excluded from the check.
    var isDuplicate: Bool {
        let candidate = SMBShare(
            name: name,
            host: host.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username,
            mountPoint: mountPoint
        )
        var probe = candidate
        if case .edit(let original) = mode { probe.id = original.id }
        return manager.isDuplicate(probe)
    }

    var saveEnabled: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isDuplicate
    }

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    HStack {
                        Text("Name")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("My Network Drive", text: $name)
                    }

                    HStack {
                        Text("Host / IP")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("192.168.1.100 or server.local", text: $host)
                    }

                    HStack {
                        Text("Share Name")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("SharedFolder", text: $shareName)
                    }

                    HStack {
                        Text("Mount Point")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Text(resolvedMountPoint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    if isDuplicate {
                        HStack {
                            Text("")
                                .frame(width: 100)
                            Text("Another share is already using this mount point. Choose a different location.")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack {
                        Text("Auto-Mount")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Toggle("", isOn: $autoMount)
                            .labelsHidden()
                        Text("Automatically connect and reconnect on disconnect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Credentials (optional)") {
                    HStack {
                        Text("Username")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("domain\\user or user", text: $username)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Password")
                            .frame(width: 100, alignment: .trailing)
                            .foregroundColor(.secondary)
                        if showPassword {
                            TextField("Password", text: $password)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Password", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }

                    Text("The password is securely stored in the macOS Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !host.isEmpty && !shareName.isEmpty {
                    Section("Preview") {
                        Text("smb://\(username.isEmpty ? "" : "\(username)@")\(host)/\(shareName)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!saveEnabled)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 500, height: 540)
        .onAppear(perform: loadExisting)
    }

    func loadExisting() {
        // .onAppear can fire more than once for sheet content on macOS; guard so the
        // keychain read happens exactly once per open.
        guard !hasLoaded else { return }
        hasLoaded = true

        if case .edit(let share) = mode {
            name = share.name
            host = share.host
            shareName = share.shareName
            username = share.username
            mountPoint = share.mountPoint
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        }

        if case .clone(let share) = mode {
            // Name intentionally left blank — the user must choose a distinct name.
            host = share.host
            shareName = share.shareName
            username = share.username
            mountPoint = share.mountPoint
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        }
    }

    func save() {
        let displayName = name.isEmpty ? "\(host)/\(shareName)" : name

        switch mode {
        case .add, .clone:
            let share = SMBShare(
                name: displayName,
                host: host,
                shareName: shareName,
                username: username,
                mountPoint: mountPoint,
                autoMount: autoMount
            )
            onSave(share, password)

        case .edit(var share):
            share.name = displayName
            share.host = host
            share.shareName = shareName
            share.username = username
            share.mountPoint = mountPoint
            share.autoMount = autoMount
            onSave(share, password)
        }
    }
}

#Preview {
    ShareEditView(mode: .add) { _, _ in }
}
