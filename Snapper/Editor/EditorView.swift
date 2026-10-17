import SwiftUI

/// Edits one Library photo: Looks, Adjust and Crop tabs over the photo, with
/// Share and Save at the bottom. Pushed from the Library.
///
/// Every change can be undone; Reset (by part or all at once) is undoable
/// too, so it needs no confirmation.
struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var showsPresets = false
    @State private var upgradeAfterPresets = false
    var onShowPaywall: () -> Void = {}
    var onShootPreset: ((SavedPreset) -> Bool)?

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            toolNavigation
            panel
            actions
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showsPresets, onDismiss: {
            if upgradeAfterPresets { upgradeAfterPresets = false; onShowPaywall() }
        }) {
            PresetsView(store: model.settings.presets, looks: model.looks, hasPremium: model.hasPremiumNow,
                        currentRecipe: model.recipe, onApply: { model.applyPreset($0) },
                        onUpgrade: { upgradeAfterPresets = true }, onShoot: onShootPreset,
                        samplePhotoURL: model.record.map { model.library.url(for: $0) })
        }
        .alert(alertTitle, isPresented: alertBinding, presenting: model.alert) { alert in
            switch alert {
            case .photosAccessDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            case .error:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .photosAccessDenied:
                Text("Allow Snapper to add photos in Settings to save your shots to your library.")
            case .error(let message):
                Text(message)
            }
        }
        .sensoryFeedback(.success, trigger: model.savedCount)
        .sensoryFeedback(.selection, trigger: model.tab)
        .onDisappear { model.finish() }
    }

    private var toolNavigation: some View {
        HStack(spacing: 4) {
            ForEach(EditorModel.Tab.allCases) { tab in
                Button {
                    withAnimation(animation) { model.tab = tab }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.body.weight(.semibold))
                        Text(tab.title).font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .foregroundStyle(model.tab == tab ? Color.black : Color.primary)
                    .background(model.tab == tab ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
        }
        .padding(5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 19))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editing tools")
    }

    private var animation: Animation? { .snapper(Motion.standard, reduceMotion: reduceMotion) }

    private var alertTitle: Text {
        switch model.alert {
        case .photosAccessDenied: Text("Photo access needed")
        case .error: Text("Couldn't finish")
        case nil: Text("")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation(animation) { model.undo() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityLabel(Text("Undo"))

            Button {
                withAnimation(animation) { model.redo() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .accessibilityLabel(Text("Redo"))
        }
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Reset Look", systemImage: "camera.filters") {
                    withAnimation(animation) { model.resetLook() }
                }
                .disabled(!model.isLookChanged)
                Button("Reset Light & Color", systemImage: "slider.horizontal.3") {
                    withAnimation(animation) { model.resetLight() }
                }
                .disabled(!model.isLightChanged)
                Button("Reset Crop", systemImage: "crop") {
                    withAnimation(animation) { model.resetCrop() }
                }
                .disabled(!model.isCropChanged)
                Button("Reset Finish", systemImage: "rectangle") {
                    withAnimation(animation) { model.resetFinish() }
                }
                .disabled(!model.isFinishChanged)
                Divider()
                Button("Reset All Edits", systemImage: "arrow.counterclockwise", role: .destructive) {
                    withAnimation(animation) { model.reset() }
                }
            } label: {
                Text("Reset")
            }
            .disabled(!model.isEdited)
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        if model.tab == .crop {
            if let base = model.cropBase {
                CropCanvas(image: base, straighten: model.straighten, rect: model.cropRect, aspect: model.cropAspect,
                           onChange: { model.setCropRect($0) },
                           onInteraction: { model.interaction(began: $0) })
                .transition(.opacity)
            } else {
                ProgressView()
            }
        } else {
            ZStack(alignment: .bottom) {
                if let image = model.displayImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        // On the photo only, so pressing the compare button doesn't also count.
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                            model.isShowingOriginal = pressing
                        })
                        .overlay(alignment: .top) {
                            if model.isShowingOriginal {
                                Text("Original")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .glassSurface(in: Capsule(), tint: .black.opacity(0.4))
                                    .padding(.top, 10)
                                    .transition(.opacity)
                            }
                        }
                        // Compare sits on the photo it compares.
                        .overlay(alignment: .bottomTrailing) { compareButton }
                        .padding(.horizontal, 16)
                        .accessibilityLabel(Text("Photo in \(model.currentLook.name)"))
                        .accessibilityHint(Text("Touch and hold to compare with the original."))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if model.showsEditsKeptHint {
                    Button {
                        model.dismissEditsKeptHint()
                    } label: {
                        Label("Edits stay in Snapper. Save to add them to Photos.", systemImage: "info.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    .accessibilityHint(Text("Dismisses this note"))
                }
            }
            .animation(animation, value: model.showsEditsKeptHint)
            .animation(.snapper(Motion.quick, reduceMotion: reduceMotion), value: model.isShowingOriginal)
        }
    }

    private var compareButton: some View {
        Button {
            model.isShowingOriginal.toggle()
        } label: {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.isShowingOriginal ? Color.black : Color.white)
                .frame(width: 36, height: 36)
                .background {
                    if model.isShowingOriginal {
                        Circle().fill(.white)
                    }
                }
                .glassSurface(in: Circle(), tint: model.isShowingOriginal ? nil : .black.opacity(0.35))
                .minimumTapTarget()
        }
        .buttonStyle(PressableButtonStyle())
        .padding(6)
        .accessibilityLabel(Text("Compare with original"))
        .accessibilityValue(model.isShowingOriginal ? Text("Showing original") : Text("Showing edit"))
    }

    // MARK: - Panels

    @ViewBuilder
    private var panel: some View {
        switch model.tab {
        case .looks: looksPanel
        case .adjust: adjustPanel
        case .crop: cropPanel
        case .finish: finishPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 8) {
            HStack {
                lookCaption
                Button("Presets", systemImage: "slider.horizontal.3") { showsPresets = true }
                    .font(.subheadline.weight(.semibold)).padding(.trailing, 16)
            }
            if let guide = LookGuide.forLook(model.currentLook.id) {
                Text(guide.bestFor).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            LookBrowser(catalog: model.catalog,
                        selectedID: model.currentLook.id,
                        thumbnails: model.lookThumbnails,
                        lockedIDs: model.lockedLookIDs,
                        favoriteIDs: Set(model.settings.favoriteLookIDs),
                        activeCategory: $model.activeCategory,
                        select: { look in withAnimation(animation) { model.select(look) } },
                        toggleFavorite: { model.toggleFavorite($0) })

            HStack(spacing: 12) {
                Text("Strength")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Slider(value: $model.strength, in: 0...1) { editing in
                    model.interaction(began: editing)
                }
                .disabled(model.currentLook.isOriginal)
                Text("\(Int((model.strength * 100).rounded()))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .opacity(model.currentLook.isOriginal ? 0.4 : 1)
        }
    }

    /// The current look's name in the camera's serif, with its collection and
    /// a star to keep it in Favorites.
    private var lookCaption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.isLocked {
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(Text("Premium look"))
            }
            Text(model.currentLook.name)
                .font(Theme.lookName(.title3))
                .tracking(-0.2)
                .layoutPriority(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
            // The collection is the first thing to go when space runs out.
            if let collection = model.collectionName, !dynamicTypeSize.isAccessibilitySize {
                Text(collection)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !model.currentLook.isOriginal {
                Button {
                    model.toggleFavorite(model.currentLook)
                } label: {
                    Image(systemName: model.isCurrentLookFavorite ? "star.fill" : "star")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(model.isCurrentLookFavorite ? Theme.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .minimumTapTarget()
                }
                .buttonStyle(PressableButtonStyle())
                .sensoryFeedback(.selection, trigger: model.isCurrentLookFavorite)
                .accessibilityLabel(model.isCurrentLookFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
            }
        }
        .lineLimit(1)
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .animation(animation, value: model.currentLook)
    }

    private var adjustPanel: some View {
        let kind = model.adjustTool
        let value = model.value(of: kind)
        let isChanged = abs(value) > 0.004
        return VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(PhotoAdjustments.Kind.allCases) { tool in
                    AdjustToolButton(kind: tool, isSelected: model.adjustTool == tool,
                                     isChanged: abs(model.value(of: tool)) > 0.004,
                                     showsTitle: !dynamicTypeSize.isAccessibilitySize) {
                        model.adjustTool = tool
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .sensoryFeedback(.selection, trigger: model.adjustTool)

            VStack(spacing: 6) {
                // Names the slider being moved; tap to put it back to zero.
                Button {
                    withAnimation(animation) { model.resetValue(of: kind) }
                } label: {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .foregroundStyle(.secondary)
                        Text(Self.formatAdjustment(value))
                            .foregroundStyle(isChanged ? Theme.accent : .white)
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumTapTarget()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!isChanged)
                .accessibilityLabel(Text("Reset \(String(localized: kind.title))"))

                RulerSlider(value: Binding(get: { model.value(of: kind) }, set: { model.setValue($0, for: kind) }),
                            range: kind.range, tickStep: 0.05,
                            onEditingChanged: { model.interaction(began: $0) })
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .id(kind)
                    .accessibilityLabel(Text(kind.title))
            }
        }
        .padding(.vertical, 2)
    }

    private var finishPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.hasPremiumNow {
                    Label("Premium finishing · preview free", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                Picker("Frame", selection: $model.frame) {
                    ForEach(PhotoFinish.Frame.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                if model.frame != .none {
                    HStack {
                        Text("Border").font(.subheadline)
                        Slider(value: $model.border, in: 0.01...0.16, onEditingChanged: { model.interaction(began: $0) })
                            .accessibilityLabel("Border width")
                    }
                }
                Picker("Export layout", selection: $model.exportLayout) {
                    ForEach(PhotoFinish.Layout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Text("Layouts fit your whole cropped photo inside the canvas.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Date stamp", isOn: $model.hasDateStamp)
                if model.hasDateStamp {
                    DatePicker("Date on photo", selection: $model.stampDate, displayedComponents: .date)
                    if model.isImported && model.record?.takenAt == nil {
                        Text("No capture date was found. Choose the date to print.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Remove All Finishing") { model.resetFinish() }
                    .disabled(!model.recipe.finish.isActive)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .frame(maxHeight: 230)
    }

    private var cropPanel: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.cropShapes) { shape in
                        shapeChip(shape)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.cropShapes) { shape in
                            shapeChip(shape)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.snapper(Motion.turn, reduceMotion: reduceMotion)) { model.rotate() }
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text("Rotate 90 degrees"))

                VStack(spacing: 5) {
                    Button {
                        withAnimation(animation) { model.straighten = 0 }
                    } label: {
                        Text("\(Self.formatDegrees(model.straighten)) Straighten")
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .foregroundStyle(abs(model.straighten) > 0.05 ? Theme.accent : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(PressableButtonStyle())
                    RulerSlider(value: $model.straighten, range: PhotoCrop.straightenRange, tickStep: 1, spacing: 8,
                                onEditingChanged: { model.interaction(began: $0) })
                        .frame(height: 24)
                        .accessibilityLabel(Text("Straighten"))
                }

                Button {
                    withAnimation(animation) { model.flip() }
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text("Flip horizontally"))
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 2)
    }

    private func shapeChip(_ shape: CropShape) -> some View {
        let isSelected = model.selectedShape == shape
        return Button {
            withAnimation(animation) { model.setShape(shape) }
        } label: {
            Text(shape.title)
                .font(.footnote.weight(isSelected ? .bold : .semibold))
                .lineLimit(1)
                // Never cut a label short: if they don't all fit, the row scrolls instead.
                .fixedSize()
                .frame(maxWidth: .infinity)
                .chip(isSelected: isSelected, horizontalPadding: 10)
                .minimumTapTarget()
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.share()
                } label: {
                    // The word goes when there's no room for it at large text sizes.
                    ViewThatFits(in: .horizontal) {
                        Label {
                            Text("Share")
                        } icon: {
                            shareIcon
                        }
                        .lineLimit(1)
                        shareIcon
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isProminent: false))
                .frame(width: 120)
                .accessibilityLabel(Text("Share"))

                Button {
                    model.save()
                } label: {
                    HStack(spacing: 8) {
                        if model.isSaving {
                            ProgressView().tint(.black)
                        } else if model.isLocked {
                            Image(systemName: "lock.fill")
                        } else if model.isSaved {
                            Image(systemName: "checkmark")
                        }
                        Text(model.saveTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isSaving)
            }
            .padding(.horizontal, 16)

            if model.isLocked {
                Text("Preview free. Premium is required to save this look or finish.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if model.savedCount > 0 && !model.hasPremiumNow {
                Button("Photo saved. Explore Premium styles", action: onShowPaywall)
                    .font(.caption.weight(.semibold))
            }

        }
        .animation(animation, value: model.isSaved)
        .animation(animation, value: model.isLocked)
    }

    @ViewBuilder
    private var shareIcon: some View {
        if model.isPreparingShare {
            ProgressView()
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }

    // MARK: - Formatting

    /// "+12", "−8", "0".
    static func formatAdjustment(_ value: Double) -> String {
        let number = Int((value * 100).rounded())
        if number > 0 { return "+\(number)" }
        if number < 0 { return "−\(-number)" }
        return "0"
    }

    /// "−2.5°", "0°".
    static func formatDegrees(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "0°" }
        let text = abs(rounded).formatted(.number.precision(.fractionLength(0...1)))
        return (rounded < 0 ? "−" : "+") + text + "°"
    }
}

/// One slider in the Adjust tab: a round icon and its name, with a yellow
/// dot when it has been moved.
private struct AdjustToolButton: View {
    let kind: PhotoAdjustments.Kind
    let isSelected: Bool
    let isChanged: Bool
    var showsTitle = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background {
                        if isSelected {
                            Circle().fill(.white)
                        } else {
                            Circle().fill(.white.opacity(0.13))
                                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isChanged {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                                .offset(x: 1, y: -1)
                        }
                    }
                if showsTitle {
                    Text(kind.title)
                        .font(.caption2.weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(isChanged ? Text("Changed") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension PhotoAdjustments.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .warmth: "Warmth"
        case .fade: "Fade"
        case .grain: "Grain"
        }
    }

    var symbolName: String {
        switch self {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop"
        case .warmth: "thermometer.medium"
        case .fade: "square.dashed"
        case .grain: "circle.grid.3x3.fill"
        }
    }
}

extension CropShape {
    var title: LocalizedStringResource {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .fourThree: "4:3"
        case .square: "1:1"
        case .sixteenNine: "16:9"
        }
    }
}
