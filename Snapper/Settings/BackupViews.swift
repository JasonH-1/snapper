import SwiftUI

/// Restores a Library backup: says what it holds, then copies it in, with
/// progress. Photos already in Snapper are left as they are.
struct BackupRestoreView: View {
    let app: AppModel
    let url: URL
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case reading
        case ready(LibraryBackup.Manifest)
        case restoring
        case finished(String)
        case failed(String)
    }

    @State private var phase = Phase.reading
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                    .contentTransition(.symbolEffect(.replace))
                content
                Spacer()
                actions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .restoring = phase {
                        Button("Stop") { restoreTask?.cancel() }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .task { await readManifest() }
    }

    private var isRestoring: Bool {
        if case .restoring = phase { return true }
        return false
    }

    private var symbol: String {
        switch phase {
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "arrow.clockwise.icloud"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            ProgressView("Reading backup…")
        case .ready(let manifest):
            VStack(spacing: 8) {
                Text("\(LibraryModel.photoCount(manifest.photos.count)) with their edits and versions")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Backed up \(manifest.createdAt.formatted(date: .long, time: .shortened)) · \(totalSize(manifest).formatted(.byteCount(style: .file)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !manifest.presets.isEmpty {
                    Text(manifest.presets.count == 1 ? "Includes 1 personal preset." : "Includes \(manifest.presets.count) personal presets.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Photos already in Snapper are left as they are; nothing is replaced.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        case .restoring:
            VStack(spacing: 10) {
                ProgressView(value: app.captures.backupProgress ?? 0)
                    .tint(Theme.accent)
                Text("Restoring… Keep Snapper open until it's done.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .finished(let message):
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .ready:
            Button("Restore to Snapper") { restore() }
                .buttonStyle(PrimaryButtonStyle())
        case .finished, .failed:
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        default:
            EmptyView()
        }
    }

    private func totalSize(_ manifest: LibraryBackup.Manifest) -> Int64 {
        manifest.photos.reduce(Int64(0)) { $0 + $1.byteCount }
    }

    private func readManifest() async {
        do {
            phase = .ready(try await CaptureLibrary.backupManifest(at: url))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func restore() {
        phase = .restoring
        restoreTask = Task {
            do {
                phase = .finished(try await app.restoreLibraryBackup(from: url))
            } catch is CancellationError {
                phase = .failed(String(localized: "Restore stopped before any photos were added."))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// What Back Up and Restore are doing. Settings keeps it and attaches
/// `backupPresentations` to its whole list: on a List section, SwiftUI copies
/// sheets to every row, and the Back Up row is swapped for a progress row
/// mid-backup, which dropped the share sheet and closed Settings with it.
@MainActor
@Observable
final class BackupFlow {
    var isBackingUp = false
    var backupFile: BackupFile?
    var errorMessage: String?
    var isPickingBackup = false
    var pickedBackup: AppModel.IncomingBackup?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    /// The temporary backup file to delete once the share sheet closes.
    @ObservationIgnored private var sharedBackupURL: URL?

    struct BackupFile: Identifiable {
        let url: URL
        let summary: LibraryBackup.Summary
        var id: URL { url }
    }

    func backUp(_ app: AppModel) {
        isBackingUp = true
        backupTask = Task {
            defer { isBackingUp = false }
            do {
                let (url, summary) = try await app.makeLibraryBackup()
                sharedBackupURL = url
                backupFile = BackupFile(url: url, summary: summary)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() { backupTask?.cancel() }

    /// Removes the temporary backup a while after the share sheet closes:
    /// an AirDrop can still be sending when it does. (A new backup also
    /// clears old ones.)
    func removeBackupFile() {
        guard let url = sharedBackupURL else { return }
        sharedBackupURL = nil
        let folder = url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(900))
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// The Back Up and Restore rows in Settings. What they open is shown by
/// `backupPresentations`, on the list around them.
struct BackupSection: View {
    let app: AppModel
    let backup: BackupFlow

    var body: some View {
        Section {
            if backup.isBackingUp {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Backing up…")
                        Spacer()
                        Button("Stop") { backup.stop() }
                    }
                    ProgressView(value: app.captures.backupProgress ?? 0)
                        .tint(Theme.accent)
                }
            } else {
                Button {
                    backup.backUp(app)
                } label: {
                    Label("Back Up Library", systemImage: "externaldrive.badge.plus")
                }
                .disabled(app.captures.records.isEmpty)
            }
            Button {
                backup.isPickingBackup = true
            } label: {
                Label("Restore from Backup", systemImage: "arrow.clockwise.icloud")
            }
            .disabled(backup.isBackingUp)
        } header: {
            Text("Backup")
        } footer: {
            Text("A backup is one file with every original, its edits and versions, plus your presets and favorites. Save it to Files or AirDrop it to your new iPhone, then open it in Snapper.")
        }
    }
}

extension View {
    /// The backup's share sheet, the file picker and restore, and errors, for
    /// `BackupSection`. Attach it to the list, not the section.
    func backupPresentations(_ backup: BackupFlow, app: AppModel) -> some View {
        modifier(BackupPresentations(backup: backup, app: app))
    }
}

private struct BackupPresentations: ViewModifier {
    @Bindable var backup: BackupFlow
    let app: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $backup.backupFile, onDismiss: { backup.removeBackupFile() }) { file in
                ShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .sheet(item: $backup.pickedBackup) { picked in
                BackupRestoreView(app: app, url: picked.url)
            }
            .fileImporter(isPresented: $backup.isPickingBackup, allowedContentTypes: [.snapperBackup]) { result in
                switch result {
                case .success(let url): backup.pickedBackup = AppModel.IncomingBackup(url: url)
                case .failure(let error): backup.errorMessage = error.localizedDescription
                }
            }
            .alert("Backup didn't finish", isPresented: Binding(get: { backup.errorMessage != nil },
                                                                 set: { if !$0 { backup.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backup.errorMessage ?? "")
            }
    }
}
