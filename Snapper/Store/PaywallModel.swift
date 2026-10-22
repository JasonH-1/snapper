import OSLog
import SwiftUI

/// Drives the paywall: plan selection, purchase/restore and the live
/// before/after slides that show premium looks on a real photo.
@MainActor
@Observable
final class PaywallModel: Identifiable {
    struct Slide: Identifiable {
        let id: String
        let look: Look
        let before: UIImage
        let after: UIImage
    }

    enum Alert: Identifiable {
        case pending
        case nothingToRestore
        case error(String)

        var id: String {
            switch self {
            case .pending: "pending"
            case .nothingToRestore: "nothing"
            case .error(let message): message
            }
        }
    }

    let context: PaywallContext
    let store: any PurchaseService
    private(set) var slides: [Slide] = []
    var slideIndex = 0
    var selectedPlanID: String?
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var didUnlock = false
    /// Lifetime is now owned while a subscription is still set to renew.
    /// Nothing is cancelled for the person, so the paywall stays open to say
    /// the subscription keeps renewing until they cancel it.
    private(set) var showsSubscriptionReminder = false
    var alert: Alert?

    @ObservationIgnored private let library: LookLibrary
    @ObservationIgnored private let renderer: PhotoRenderer
    @ObservationIgnored private let photoURL: URL?

    /// - Parameter photoURL: one of the person's own captures to show the looks
    ///   on (more convincing than stock images); falls back to showcase photos.
    init(context: PaywallContext, store: any PurchaseService, library: LookLibrary, renderer: PhotoRenderer, photoURL: URL?) {
        self.context = context
        self.store = store
        self.library = library
        self.renderer = renderer
        self.photoURL = photoURL
    }

    /// The offer at the end of onboarding, which says plainly how to skip it.
    var isIntro: Bool {
        if case .intro = context { true } else { false }
    }

    /// Subscribers switching to Lifetime are offered only Lifetime.
    var offersOnlyLifetime: Bool {
        if case .switchToLifetime = context { true } else { false }
    }

    /// Whether the subscriber's current subscription will renew. Once they
    /// have turned off auto-renew there is nothing left to tell them to cancel.
    var subscriptionWillRenew: Bool { store.subscriptionWillRenew }

    var plans: [SubscriptionPlan] {
        offersOnlyLifetime ? store.plans.filter { !$0.period.renews } : store.plans
    }

    var selectedPlan: SubscriptionPlan? {
        plans.first { $0.id == selectedPlanID } ?? plans.first
    }

    var premiumLookCount: Int { library.premiumLooks.count }
    var totalLookCount: Int { library.looks.count - 1 }

    /// How much the yearly plan saves over twelve months of the monthly plan.
    var yearlySavingsPercent: Int? {
        guard let yearly = plans.first(where: { $0.period == .year }),
              let monthly = plans.first(where: { $0.period == .month }),
              monthly.price > 0 else { return nil }
        let annualMonthly = monthly.price * 12
        let ratio = NSDecimalNumber(decimal: (annualMonthly - yearly.price) / annualMonthly).doubleValue
        let percent = Int((ratio * 100).rounded(.down))
        return percent >= 10 ? percent : nil
    }

    var title: String {
        switch context {
        case .lockedLook(let look, _, _):
            look.isPremium
                ? String(localized: "Keep \(look.name) with Premium")
                : String(localized: "Export your edits with Premium")
        case .intro:
            String(localized: "Try every look and tool")
        case .upgrade:
            String(localized: "Your style, in every photo")
        case .switchToLifetime:
            String(localized: "Keep Premium for good")
        }
    }

    // MARK: - Loading

    func load() async {
        let plansTask = Task { await store.loadPlans() }
        await loadSlides()
        await plansTask.value
        if selectedPlanID == nil {
            selectedPlanID = plans.first?.id
        }
    }

    private func loadSlides() async {
        var result: [Slide] = []
        if case .lockedLook(let look, let before, let after) = context, let before, let after {
            result.append(Slide(id: "locked-\(look.id)", look: look, before: before, after: after))
        }
        for (look, url) in showcasePairs() {
            guard result.count < 4, !result.contains(where: { $0.look.id == look.id }) else { continue }
            async let before = renderer.showcase(url: url, look: .original)
            async let after = renderer.showcase(url: url, look: look)
            if let before = await before, let after = await after {
                result.append(Slide(id: "\(look.id)-\(url.lastPathComponent)", look: look, before: before, after: after))
                slides = result
            }
        }
        slides = result
    }

    /// One premium look from each collection, each on a different photo,
    /// newest collection first.
    private func showcasePairs() -> [(Look, URL)] {
        let preferred = ["afterparty", "sunburn", "neon", "peach", "lantern", "honey", "arcade"]
        var looks = preferred.compactMap(library.look(id:)).filter(\.isPremium)
        if looks.isEmpty { looks = Array(library.premiumLooks.prefix(3)) }
        var seenCollections = Set<String>()
        looks = looks.filter { seenCollections.insert($0.collectionID ?? $0.id).inserted }

        var photos: [URL] = []
        if let photoURL { photos.append(photoURL) }
        for name in ["showcase-portrait", "showcase-cafe", "showcase-night"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg") { photos.append(url) }
        }
        guard !photos.isEmpty else { return [] }
        return looks.enumerated().map { index, look in (look, photos[index % photos.count]) }
    }

    func advanceSlide() {
        guard slides.count > 1 else { return }
        slideIndex = (slideIndex + 1) % slides.count
    }

    // MARK: - Actions

    func purchase() async {
        guard let plan = selectedPlan, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await store.purchase(plan) {
            case .purchased:
                if store.ownsLifetimeWithRenewingSubscription {
                    showsSubscriptionReminder = true
                } else {
                    didUnlock = store.isPremium
                }
            case .pending:
                alert = .pending
            case .cancelled:
                break
            }
        } catch {
            Logger.store.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            alert = .error(error.localizedDescription)
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let isPremium = try await store.restore()
            if store.ownsLifetimeWithRenewingSubscription {
                showsSubscriptionReminder = true
            } else if isPremium && (!offersOnlyLifetime || store.ownsLifetime) {
                didUnlock = true
            } else {
                // Nothing found or, when switching to Lifetime, only the
                // subscription the person already has.
                alert = .nothingToRestore
            }
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    /// Offer codes are for people without Premium; a subscriber switching to
    /// Lifetime isn't offered one.
    var offersCodeRedemption: Bool { !offersOnlyLifetime }

    /// After the App Store's offer code sheet closes. A redeemed code arrives
    /// as a transaction like any purchase; checking entitlements now unlocks
    /// without waiting for it. The sheet confirms or explains the code itself.
    func codeRedemptionEnded(_ result: Result<Void, any Error>) async {
        if case .failure(let error) = result {
            Logger.store.error("Offer code redemption failed: \(error.localizedDescription, privacy: .public)")
            alert = .error(error.localizedDescription)
            return
        }
        await store.refreshEntitlements()
        if offersCodeRedemption && store.isPremium { didUnlock = true }
    }
}
