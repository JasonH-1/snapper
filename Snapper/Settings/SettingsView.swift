import StoreKit
import SwiftUI

/// Settings: subscription, photo saving, favourites, support and legal.
struct SettingsView: View {
    @Bindable var app: AppModel
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var showManageSubscriptions = false
    @State private var isRestoring = false
    @State private var restoreMessage: RestoreMessage?

    private struct RestoreMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    var body: some View {
        NavigationStack {
            List {
                premiumSection
                photosSection
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
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
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
                        Text("Snapper Premium")
                            .font(.headline)
                        Text("Active — every look unlocked, no watermark.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.premiumGradient)
                }
                Button("Manage Subscription") { showManageSubscriptions = true }
            } else {
                Button {
                    app.presentPaywall(.upgrade)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Premium")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("All \(app.library.looks.count - 1) looks and no watermark.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.premiumGradient)
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
        } header: {
            Text("Premium")
        } footer: {
            if !app.hasPremium {
                Text("Free exports include a small Snapper watermark. Premium removes it.")
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
            Text("New shots are always kept in Snapper so you can change the look later. Saving the original adds an unfiltered copy to your library too.")
        }
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
                                     detail: String(localized: "No active Snapper Premium subscription was found for this Apple ID."))
            } catch {
                restoreMessage = RestoreMessage(title: String(localized: "Restore didn't complete"),
                                                detail: error.localizedDescription)
            }
        }
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
                    .foregroundStyle(settings.isFavorite(look) ? Color.yellow : Color.secondary)
                    .font(.system(size: 18))
            }
        }
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(settings.isFavorite(look) ? Text("Favorite") : Text(""))
    }
}
