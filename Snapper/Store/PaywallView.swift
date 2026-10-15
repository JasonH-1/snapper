import SwiftUI

/// Snapper Premium paywall: live before/after of premium looks, plan choice,
/// clear pricing and renewal terms, restore, and legal links.
struct PaywallView: View {
    @Bindable var model: PaywallModel
    var onClose: () -> Void

    @State private var slideTimer: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    hero
                    header
                    benefits
                    plans
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            // The button and its price summary stay on screen on every iPhone size.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                callToAction
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(.bar)
            }
            closeButton
        }
        .task {
            await model.load()
        }
        .onAppear(perform: startSlideshow)
        .onDisappear { slideTimer?.cancel() }
        .onChange(of: model.didUnlock) { _, unlocked in
            if unlocked { onClose() }
        }
        .sensoryFeedback(.success, trigger: model.didUnlock)
        .sensoryFeedback(.selection, trigger: model.selectedPlanID)
        .alert(alertTitle, isPresented: alertBinding, presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            switch alert {
            case .pending:
                Text("Your purchase is waiting for approval. Premium unlocks as soon as it's approved.")
            case .nothingToRestore:
                Text("No active Snapper Premium subscription was found for this Apple ID.")
            case .error(let message):
                Text(message)
            }
        }
    }

    // MARK: - Sections

    private var background: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(.trailing, 16)
        .padding(.top, 8)
        .accessibilityLabel(Text("Close"))
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if model.slides.indices.contains(model.slideIndex) {
                let slide = model.slides[model.slideIndex]
                BeforeAfterView(before: slide.before, after: slide.after)
                    .id(slide.id)
                    .transition(.opacity)
                Text(slide.look.name)
                    .font(Theme.lookTitle(size: 22))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .allowsHitTesting(false)
                    .id("name-\(slide.id)")
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView() }
            }
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(alignment: .bottom) {
            if model.slides.count > 1 {
                HStack(spacing: 6) {
                    ForEach(model.slides.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == model.slideIndex ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.4)))
                            .frame(width: index == model.slideIndex ? 16 : 6, height: 6)
                    }
                }
                .padding(.bottom, 12)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.slideIndex)
        .padding(.top, 52)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("SNAPPER PREMIUM")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(Theme.accent)
            Text(model.title)
                .font(Theme.lookTitle(size: 30))
                .multilineTextAlignment(.center)
            Text("All \(model.totalLookCount) looks across Disposable, Neon Nights and Soft Portrait, without a watermark.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit(symbol: "camera.filters", title: Text("\(model.premiumLookCount) premium looks"),
                    detail: Text("Every collection, complete. Preview them live, keep the ones you love."))
            benefit(symbol: "checkmark.seal", title: Text("No watermark"),
                    detail: Text("Clean, full-resolution photos when you save or share."))
            benefit(symbol: "calendar.badge.clock", title: Text("Cancel anytime"),
                    detail: Text("Manage your subscription in your Apple ID settings."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }

    private func benefit(symbol: String, title: Text, detail: Text) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.subheadline.weight(.semibold))
                detail.font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var plans: some View {
        switch model.store.plansState {
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.store.loadPlans() }
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        default:
            if model.plans.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.plans) { plan in
                        PlanCard(plan: plan,
                                 isSelected: plan.id == model.selectedPlan?.id,
                                 savingsPercent: plan.period == .year ? model.yearlySavingsPercent : nil)
                            .onTapGesture { model.selectedPlanID = plan.id }
                    }
                }
            }
        }
    }

    private var callToAction: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.purchase() }
            } label: {
                HStack {
                    if model.isPurchasing {
                        ProgressView().tint(.black)
                    }
                    Text(ctaTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectedPlan == nil || model.isPurchasing || model.isRestoring)

            if let plan = model.selectedPlan {
                Text(billingSummary(for: plan))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button {
                    Task { await model.restore() }
                } label: {
                    if model.isRestoring {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(model.isRestoring || model.isPurchasing)
                Link("Terms of Use", destination: AppConfig.termsOfUseURL)
                Link("Privacy Policy", destination: AppConfig.privacyPolicyURL)
            }
            .font(.footnote.weight(.medium))
            .tint(.primary)

            Text("Payment is charged to your Apple ID at confirmation of purchase, or when the free trial ends. The subscription renews automatically at the same price and period unless it is cancelled at least 24 hours before the end of the current period. You can manage or cancel it in your App Store account settings. Any unused part of a free trial is forfeited when you buy a subscription.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Copy

    private var ctaTitle: String {
        guard let plan = model.selectedPlan else { return String(localized: "Continue") }
        if let trial = plan.freeTrial {
            return String(localized: "Start \(trial.shortLabel) Free Trial")
        }
        return String(localized: "Subscribe")
    }

    private func billingSummary(for plan: SubscriptionPlan) -> String {
        if let trial = plan.freeTrial {
            return String(localized: "\(trial.duration) free, then \(plan.displayPrice) per \(plan.period.unitName). Auto-renews; cancel anytime.")
        }
        return String(localized: "\(plan.displayPrice) per \(plan.period.unitName). Auto-renews; cancel anytime.")
    }

    private var alertTitle: Text {
        switch model.alert {
        case .pending: Text("Purchase pending")
        case .nothingToRestore: Text("Nothing to restore")
        case .error: Text("Purchase didn't complete")
        case nil: Text("")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    private func startSlideshow() {
        slideTimer?.cancel()
        slideTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                model.advanceSlide()
            }
        }
    }
}

/// One selectable subscription option. The billed amount is the most
/// prominent price on the card, as App Review requires.
private struct PlanCard: View {
    let plan: SubscriptionPlan
    let isSelected: Bool
    let savingsPercent: Int?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plan.period.adjective)
                        .font(.headline)
                    if let savingsPercent {
                        Text("Save \(savingsPercent)%")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(plan.displayPrice)
                    .font(.title3.weight(.bold))
                Text("per \(plan.period.unitName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary),
                              lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var detail: String {
        var parts: [String] = []
        if let monthly = plan.monthlyEquivalent {
            parts.append(String(localized: "\(monthly)/month"))
        }
        if let trial = plan.freeTrial {
            parts.append(String(localized: "\(trial.duration) free"))
        } else if plan.monthlyEquivalent == nil {
            parts.append(String(localized: "Billed \(plan.period.adjective.lowercased())"))
        }
        return parts.joined(separator: " · ")
    }
}
