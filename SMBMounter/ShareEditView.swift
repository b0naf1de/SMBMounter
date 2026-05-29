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
    @State private var mountPointText: String = ""
    @State private var mountPointCustomized: Bool = false
    @State private var autoMount: Bool = true
    @State private var showPassword: Bool = false
    @State private var hasLoaded = false

    // Mount-point creation flow
    @State private var showCreateConfirm = false
    @State private var pendingRequiresAuth = false
    @State private var isPreparing = false
    @State private var prepError: String? = nil

    var title: String {
        switch mode {
        case .add:   return "Add Share"
        case .edit:  return "Edit Share"
        case .clone: return "Clone Share"
        }
    }
    
    var mountPointBinding: Binding<String> {
        Binding(
            get: { mountPointText },
            set: { newValue in
                mountPointText = newValue
                mountPointCustomized = !newValue.isEmpty
            }
        )
    }

    /// The mount point that will actually be used (the default when left blank).
    var effectiveMountPoint: String {
        mountPointText.isEmpty ? "/Volumes/\(shareName.isEmpty ? "ShareName" : shareName)" : mountPointText
    }

    var preparation: ShareManager.MountPointPreparation {
        ShareManager.mountPointPreparation(mountPoint: effectiveMountPoint, shareName: shareName)
    }

    /// The hard-blocking reason (only for structurally unusable paths), shown in red.
    var mountPointError: String? {
        if case .unusable(let reason) = preparation { return reason }
        return nil
    }

    /// Explains, per state, where the share will mount and whether saving will create
    /// the folder and/or require administrator authorization.
    var mountMethodHint: String {
        switch preparation {
        case .finderManaged:
            return "Mounts via Finder at \(effectiveMountPoint) (no admin password needed)."
        case .ready:
            return "Mounts at \(effectiveMountPoint)."
        case .needsCreation(let requiresAuth):
            return requiresAuth
                ? "This folder doesn't exist. Saving will create it and ask for administrator authorization."
                : "This folder doesn't exist. Saving will create it (no admin password needed)."
        case .needsPermissionFix:
            return "You don't have access to this folder. Saving will set its ownership and ask for administrator authorization."
        case .unusable:
            return ""
        }
    }

    /// True when the current field values exactly match an existing share (same host,
    /// shareName, and resolved mount point). Editing a share excludes itself.
    var isDuplicate: Bool {
        let candidate = SMBShare(
            name: name,
            host: host.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username,
            mountPoint: mountPointText
        )
        // When editing, inject the original id so the check skips this share itself.
        var probe = candidate
        if case .edit(let original) = mode { probe.id = original.id }
        return manager.isDuplicate(probe)
    }

    var saveEnabled: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        mountPointError == nil &&
        !isDuplicate &&
        !isPreparing
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
                        TextField("/Volumes/SharedFolder", text: mountPointBinding)
                            .autocorrectionDisabled()
                    }
                    .onChange(of: shareName) { _, newValue in
                        if !mountPointCustomized {
                            mountPointText = newValue.isEmpty ? "" : "/Volumes/\(newValue)"
                        }
                    }

                    HStack(alignment: .top) {
                        Text("")
                            .frame(width: 100)
                        if let error = mountPointError {
                            Text(error + " Choose a different mount point.")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if isDuplicate {
                            Text("Another share is already using this mount point. Choose a different location.")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(mountMethodHint)
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                if isPreparing {
                    ProgressView().scaleEffect(0.6)
                }
                Button("Save") { attemptSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!saveEnabled)
                    .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 500, height: 540)
        .onAppear(perform: loadExisting)
        .alert("Create mount point?", isPresented: $showCreateConfirm) {
            Button("Create") { performPreparationAndSave() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(createConfirmMessage)
        }
        .alert("Couldn't prepare mount point", isPresented: Binding(
            get: { prepError != nil },
            set: { if !$0 { prepError = nil } }
        )) {
            Button("OK", role: .cancel) { prepError = nil }
        } message: {
            Text(prepError ?? "")
        }
    }

    var createConfirmMessage: String {
        let base: String
        if case .needsPermissionFix = preparation {
            base = "“\(effectiveMountPoint)” needs its ownership updated so this share can mount there."
        } else {
            base = "The folder “\(effectiveMountPoint)” doesn't exist yet and will be created."
        }
        return pendingRequiresAuth
            ? base + "\n\nmacOS will ask for your administrator password."
            : base
    }

    func attemptSave() {
        switch preparation {
        case .finderManaged, .ready:
            save()
            dismiss()
        case .needsCreation(let requiresAuth):
            pendingRequiresAuth = requiresAuth
            showCreateConfirm = true
        case .needsPermissionFix:
            pendingRequiresAuth = true
            showCreateConfirm = true
        case .unusable:
            break   // Save is disabled in this state
        }
    }

    func performPreparationAndSave() {
        isPreparing = true
        let path = effectiveMountPoint
        DispatchQueue.global(qos: .userInitiated).async {
            let error = ShareManager.prepareMountPoint(path)
            DispatchQueue.main.async {
                isPreparing = false
                if let error = error {
                    prepError = error
                } else {
                    save()
                    dismiss()
                }
            }
        }
    }
    
    func loadExisting() {
        // .onAppear can fire more than once for sheet content on macOS; guard so the
        // keychain read (getPassword) happens exactly once per open — otherwise the
        // user is prompted for keychain access twice.
        guard !hasLoaded else { return }
        hasLoaded = true

        if case .edit(let share) = mode {
            name = share.name
            host = share.host
            shareName = share.shareName
            username = share.username
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
            if share.mountPoint.isEmpty {
                mountPointText = "/Volumes/\(share.shareName)"
                mountPointCustomized = false
            } else {
                mountPointText = share.mountPoint
                mountPointCustomized = true
            }
        }

        if case .clone(let share) = mode {
            // Name intentionally left blank — the user must choose a distinct name.
            host = share.host
            shareName = share.shareName
            username = share.username
            autoMount = share.autoMount
            password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
            if share.mountPoint.isEmpty {
                mountPointText = "/Volumes/\(share.shareName)"
                mountPointCustomized = false
            } else {
                mountPointText = share.mountPoint
                mountPointCustomized = true
            }
        }
    }
    
    func save() {
        let displayName = name.isEmpty ? "\(host)/\(shareName)" : name
        
        switch mode {
        case .add:
            let share = SMBShare(
                name: displayName,
                host: host,
                shareName: shareName,
                username: username,
                mountPoint: mountPointText,
                autoMount: autoMount
            )
            onSave(share, password)

        case .edit(var share):
            share.name = displayName
            share.host = host
            share.shareName = shareName
            share.username = username
            share.mountPoint = mountPointText
            share.autoMount = autoMount
            onSave(share, password)

        case .clone:
            // Clone always creates a new share with a fresh UUID (via the default initializer).
            let share = SMBShare(
                name: displayName,
                host: host,
                shareName: shareName,
                username: username,
                mountPoint: mountPointText,
                autoMount: autoMount
            )
            onSave(share, password)
        }
    }
}

#Preview {
    ShareEditView(mode: .add) { _, _ in }
}
