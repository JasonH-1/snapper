import StoreKit
import SwiftUI

/// Settings: subscription, photo saving, favourites, support and legal.
struct SettingsView: View {
    @Bindable var app: AppModel
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var showManageSubscriptions = false
    @State private var showGuide = false
    @State private var guideDestination: GuideDestination?
    @State private var isRestoring = false
    @State private var isRedeemingCode = false
    @State private var restoreMessage: RestoreMessage?
    @State private var storageUsed: Int64?
    @State private var showClearConfirmation = false
    @State private var backup = BackupFlow()

    private struct RestoreMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showGuide = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Snapper Guide").font(.headline)
                                Text("Camera, looks, editing and saving — with visual examples")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "book.closed").foregroundStyle(Theme.accent) }
                    }.foregroundStyle(.primary)
                }
                premiumSection
                photosSection
                exportSection
                librarySection
                BackupSection(app: app, backup: backup)
                cameraSection
                looksSection
                supportSection
                aboutSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
            .fullScreenCover(isPresented: $showGuide, onDismiss: {
                if let destination = guideDestination {
                    guideDestination = nil
                    app.pendingGuideDestination = destination
                    onClose()
                }
            }) {
                GuideView(library: app.library) { destination in
                    guideDestination = destination
                    showGuide = false
                }
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .offerCodeRedemption(isPresented: $isRedeemingCode, onCompletion: codeRedemptionEnded)
            .backupPresentations(backup, app: app)
            .alert(restoreMessage?.title ?? "", isPresented: restoreAlertBinding, presenting: restoreMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message.detail)
            }
        }
    }

    // MARK: - Sections

    private var premiumSection: some View {
        Section {
            if app.hasPremium {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        (app.store.ownsLifetime ? Text("Snapper Premium Lifetime") : Text("Snapper Premium"))
                            .font(.headline)
                        (app.store.ownsLifetime
                         ? Text("Yours to keep: every current and future look and tool.")
                         : Text("Active — all looks, unlimited presets, batch styling and finishing."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                }
                // With Lifetime, the subscription is only worth managing while
                // it will still renew.
                if !app.store.ownsLifetime || app.store.subscriptionWillRenew {
                    Button("Manage Subscription") { showManageSubscriptions = true }
                }
                // A quiet way for subscribers to pay once instead; never prompted.
                if app.store.hasActiveSubscription && !app.store.ownsLifetime {
                    Button {
                        app.presentPaywall(.switchToLifetime)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Switch to Lifetime")
                                Text("Pay once and keep every current and future look and tool.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "infinity")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } else {
                Button {
                    app.presentPaywall(.upgrade)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Premium")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("All \(app.library.looks.count - 1) looks, personal presets and finishing tools.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            Button {
                restore()
            } label: {
                HStack {
                    Text("Restore Purchases")
                    Spacer()
                    if isRestoring { ProgressView() }
                }
            }
            .disabled(isRestoring)
            Button("Redeem Code") { isRedeemingCode = true }
        } header: {
            Text("Premium")
        } footer: {
            if !app.hasPremium {
                Text("\(app.library.freeLooks.count - 1) looks, basic editing with highlights and shadows, a date stamp and one personal preset are free. Exports are watermark-free, and any photo can be saved without its Premium parts.")
            } else if app.store.ownsLifetimeWithRenewingSubscription {
                Text("You own Lifetime, so you can cancel your subscription in Manage Subscription to stop renewals.")
            }
        }
    }

    private var photosSection: some View {
        Section {
            Toggle("Save to Photos Automatically", isOn: Bindable(app.settings).autoSaveToPhotos)
            Toggle("Also Save Original Photo", isOn: Bindable(app.settings).alsoSaveOriginal)
        } header: {
            Text("Photos")
        } footer: {
            Text("New shots are always kept in Snapper's Library so you can change the look later. Saving the original adds an unfiltered copy to your library too.")
        }
    }

    private var exportSection: some View {
        let options = Bindable(app.settings).exportOptions
        return Section {
            Picker("Format", selection: options.format) {
                Text("HEIF").tag(PhotoRenderer.ExportFormat.heic)
                Text("JPEG").tag(PhotoRenderer.ExportFormat.jpeg)
            }
            Picker("Size", selection: options.size) {
                ForEach(ExportOptions.Size.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text(app.settings.exportOptions.quality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: options.quality, in: ExportOptions.qualityRange, step: 0.05)
                    .accessibilityLabel(Text("Quality"))
            }
            Toggle("Include Location", isOn: options.includesLocation)
        } header: {
            Text("Saving & Sharing")
        } footer: {
            Text("Used when you save or share from the editor or the Library; the editor's export options show the file size for each photo. HEIF files are about half the size of JPEG; JPEG opens everywhere. Photos saved automatically from the camera are always full size.")
        }
    }

    private var librarySection: some View {
        let savedCount = app.captures.alreadySavedIDs.count
        return Section {
            if let message = app.captures.storageError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                Button("Retry Library") {
                    Task {
                        guard await app.captures.load() else { return }
                        do {
                            try await app.captures.flush()
                            await app.importLockScreenPhotos()
                        } catch { /* The Library keeps the error visible for another retry. */ }
                    }
                }
            }
            LabeledContent("Photos in Snapper") {
                if let storageUsed {
                    Text("\(LibraryModel.photoCount(app.captures.records.count)) · \(storageUsed.formatted(.byteCount(style: .file)))")
                } else {
                    Text(LibraryModel.photoCount(app.captures.records.count))
                }
            }
            Button("Clear Photos Already Saved", role: .destructive) {
                showClearConfirmation = true
            }
            .disabled(savedCount == 0)
            .confirmationDialog(Text("Remove \(LibraryModel.photoCount(savedCount)) from Snapper?"),
                                isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Remove from Snapper", role: .destructive) {
                    app.captures.deleteAlreadySaved()
                    Task { storageUsed = await app.captures.storageUsed() }
                }
            } message: {
                Text("Their current edits are already in your photo library. You won't be able to change their looks in Snapper afterwards.")
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Snapper keeps every photo you take or import until you delete it, so you can always change its look. Clearing frees space by removing photos already saved with their current edits.")
        }
        .task(id: app.captures.records.count) {
            storageUsed = await app.captures.storageUsed()
        }
    }

    private var cameraSection: some View {
        Section {
            Picker("Photo Size", selection: Bindable(app.settings).photoMegapixels) {
                ForEach(megapixelOptions, id: \.self) { megapixels in
                    Text("\(megapixels) MP").tag(megapixels)
                }
            }
            Toggle("Mirror Front Camera", isOn: Bindable(app.settings).mirrorFrontCamera)
            Toggle("Volume Buttons Take Photos", isOn: Bindable(app.settings).volumeButtonShutter)
        } header: {
            Text("Camera")
        } footer: {
            Text("Mirror Front Camera saves selfies the way the preview shows them. The volume buttons need iOS 18 or later and also work with Camera Control.")
        }
    }

    /// The sizes this camera offers, plus the current choice so the picker
    /// always has a selection.
    private var megapixelOptions: [Int] {
        Array(Set(app.camera.capabilities.photoMegapixels + [app.settings.photoMegapixels])).sorted()
    }

    private var looksSection: some View {
        Section {
            NavigationLink {
                FavoritesView(library: app.library, settings: app.settings, thumbnails: app.lookThumbnails)
            } label: {
                HStack {
                    Label("Favorite Looks", systemImage: "star")
                    Spacer()
                    if !app.settings.favoriteLookIDs.isEmpty {
                        Text("\(app.settings.favoriteLookIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Looks")
        } footer: {
            Text("Favorites come first when you swipe through looks on the camera.")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            Button {
                rateApp()
            } label: {
                Label("Rate Snapper", systemImage: "heart")
            }
            Button {
                contactSupport()
            } label: {
                Label("Contact Support", systemImage: "envelope")
            }
            Link(destination: AppConfig.termsOfUseURL) {
                Label("Terms of Use", systemImage: "doc.text")
            }
            Link(destination: AppConfig.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
        .tint(.primary)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionString)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Made by \(AppConfig.developerName). Photos never leave your iPhone unless you save or share them.")
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            Button("Replay Onboarding") {
                app.settings.hasCompletedOnboarding = false
                app.settings.hasSeenIntroPaywall = false
                onClose()
            }
        }
    }
    #endif

    private var restoreAlertBinding: Binding<Bool> {
        Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })
    }

    // MARK: - Actions

    private func restore() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                let active = try await app.store.restore()
                restoreMessage = active
                    ? RestoreMessage(title: String(localized: "Purchases restored"),
                                     detail: String(localized: "Snapper Premium is active on this iPhone."))
                    : RestoreMessage(title: String(localized: "Nothing to restore"),
                                     detail: String(localized: "No Snapper Premium purchase or active subscription was found for this Apple ID."))
            } catch {
                restoreMessage = RestoreMessage(title: String(localized: "Restore didn't complete"),
                                                detail: error.localizedDescription)
            }
        }
    }

    /// After the App Store's offer code sheet closes. A redeemed code arrives
    /// as a transaction like any purchase; checking now shows Premium at once.
    private func codeRedemptionEnded(_ result: Result<Void, any Error>) {
        if case .failure(let error) = result {
            restoreMessage = RestoreMessage(title: String(localized: "Couldn't redeem a code"),
                                            detail: error.localizedDescription)
            return
        }
        Task { await app.store.refreshEntitlements() }
    }

    private func rateApp() {
        if let id = AppConfig.appStoreID,
           let url = URL(string: "https://apps.apple.com/app/id\(id)?action=write-review") {
            openURL(url)
        } else {
            requestReview()
        }
    }

    private func contactSupport() {
        let subject = "Snapper Support (\(Self.versionString))"
        let body = "\n\n\n—\nApp: Snapper \(Self.versionString)\nDevice: \(Self.deviceModel), iOS \(UIDevice.current.systemVersion)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppConfig.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = components.url {
            openURL(url)
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Hardware identifier such as "iPhone17,1", useful in support emails.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Star the looks you reach for most.
struct FavoritesView: View {
    let library: LookLibrary
    @Bindable var settings: AppSettings
    let thumbnails: LookThumbnails

    var body: some View {
        List {
            ForEach(library.collections) { collection in
                Section(collection.name) {
                    ForEach(library.looks.filter { $0.collectionID == collection.id }) { look in
                        row(look)
                    }
                }
            }
        }
        .navigationTitle("Favorite Looks")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.favoriteLookIDs)
    }

    private func row(_ look: Look) -> some View {
        Button {
            settings.toggleFavorite(look)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let image = thumbnails.images[look.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.name).foregroundStyle(.primary)
                    Text(look.isPremium ? "Premium" : "Free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: settings.isFavorite(look) ? "star.fill" : "star")
                    .foregroundStyle(settings.isFavorite(look) ? Theme.accent : Color.secondary)
                    .font(.system(size: 18))
            }
        }
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(settings.isFavorite(look) ? Text("Favorite") : Text(""))
    }
}
