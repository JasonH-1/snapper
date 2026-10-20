import SwiftUI

/// Edits one Library photo: Looks, Adjust and Crop tabs over the photo, with
/// Share and Save at the bottom. Pushed from the Library.
///
/// Every change can be undone; Reset (by part or all at once) is undoable
/// too, so it needs no confirmation.
struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var showsPresets = false
    @State private var showsCollections = false
    @State private var upgradeAfterPresets = false
    @State private var showsVersions = false
    @State private var showsExportOptions = false
    @State private var canvasController = CanvasController()
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
        // While Export is open, it presents the share sheet itself.
        .sheet(item: showsExportOptions ? .constant(nil) : $model.shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showsVersions) {
            VersionsView(model: model)
        }
        .sheet(isPresented: $showsExportOptions) {
            ExportOptionsView(model: model)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsCollections) {
            CuratedCollectionsView(library: model.looks, renderer: model.library.renderer) { style in
                model.applyCuratedStyle(style)
            }
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

    /// Every tool in one row: equal widths when they all fit (the usual
    /// case), scrolling only at large text sizes. Selection is white, like
    /// the other tabs and chips; yellow stays for Save.
    private var toolNavigation: some View {
        ViewThatFits(in: .horizontal) {
            toolTabs(fillsWidth: true)
            ScrollView(.horizontal, showsIndicators: false) {
                toolTabs(fillsWidth: false)
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editing tools")
    }

    private func toolTabs(fillsWidth: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(EditorModel.Tab.allCases) { tab in
                let isSelected = model.tab == tab
                Button {
                    withAnimation(animation) { model.tab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, fillsWidth ? 2 : 10)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 52)
                    .contentShape(Rectangle())
                    .foregroundStyle(isSelected ? Color.black : Color.primary)
                    .background(isSelected ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
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
                Button("Reset Selective Edits", systemImage: "person.crop.rectangle") { model.resetSelective() }
                    .disabled(!model.recipe.selective.isActive)
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
                if model.displayImage != nil {
                    ZoomableCanvas(image: model.displayImage,
                                   overlay: model.showsMaskOverlay ? model.maskOverlay : nil,
                                   brush: model.isBrushActive ? CanvasBrush(diameter: model.brushSize, mode: model.brushMode) : nil,
                                   controller: canvasController,
                                   onStroke: { model.handleStroke($0) },
                                   onPress: { pressing in
                                       if !model.isBrushActive { model.isShowingOriginal = pressing }
                                   },
                                   onZoom: { model.canvasZoom = $0 })
                        // The badges and buttons sit on the photo itself, which is
                        // fitted inside the canvas, not in the space around it.
                        .overlay {
                            PhotoBoundsOverlay(imageSize: model.displayImage?.size) {
                                if model.isShowingOriginal {
                                    Text("Original")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .glassSurface(in: Capsule(), tint: .black.opacity(0.4))
                                        .padding(.top, 10)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                        .transition(.opacity)
                                        .allowsHitTesting(false)
                                }
                                versionsButton
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                zoomBadge
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                compareButton
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            }
                        }
                        .padding(.horizontal, 16)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Photo in \(model.currentLook.name)"))
                        .accessibilityHint(model.isBrushActive
                                           ? Text("Paint with one finger. Pinch with two fingers to zoom.")
                                           : Text("Pinch or double-tap to zoom. Touch and hold to compare with the original."))
                        .accessibilityAction(named: Text("Zoom In")) { canvasController.zoomIn() }
                        .accessibilityAction(named: Text("Zoom Out")) { canvasController.zoomOut() }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let notice = model.versionNotice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if model.showsEditsKeptHint {
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
            .animation(animation, value: model.versionNotice)
            .animation(.snapper(Motion.quick, reduceMotion: reduceMotion), value: model.isShowingOriginal)
        }
    }

    /// Which version is showing; opens the versions.
    private var versionsButton: some View {
        Button {
            showsVersions = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.versionLabel ?? String(localized: "Versions"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glassSurface(in: Capsule(), tint: .black.opacity(0.35))
            .minimumTapTarget()
        }
        .buttonStyle(PressableButtonStyle())
        .padding(6)
        .accessibilityLabel(Text("Versions"))
        .accessibilityValue(Text(model.versionLabel ?? String(localized: "No versions")))
    }

    /// The zoom level while zoomed in; tap to see the whole photo again.
    @ViewBuilder
    private var zoomBadge: some View {
        if model.canvasZoom > 1.05 {
            Button {
                canvasController.fit()
            } label: {
                Text("\(model.canvasZoom, format: .number.precision(.fractionLength(1)))× · Fit")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .glassSurface(in: Capsule(), tint: .black.opacity(0.35))
                    .minimumTapTarget()
            }
            .buttonStyle(PressableButtonStyle())
            .padding(6)
            .transition(.opacity)
            .accessibilityLabel(Text("Zoomed \(model.canvasZoom, format: .number.precision(.fractionLength(1))) times. Fit photo"))
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
        case .curves: CurvesPanel(model: model)
        case .color: ColorPanel(model: model)
        case .selective: SelectiveEditPanel(model: model)
        case .crop: cropPanel
        case .finish: finishPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 6) {
            lookCaption
            HStack(spacing: 8) {
                Button { showsCollections = true } label: {
                    Label("Collections", systemImage: "square.stack")
                        .font(.footnote.weight(.semibold))
                        .chip(isSelected: false)
                        .minimumTapTarget()
                }
                Button { showsPresets = true } label: {
                    Label("Presets", systemImage: "slider.horizontal.3")
                        .font(.footnote.weight(.semibold))
                        .chip(isSelected: false)
                        .minimumTapTarget()
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, 16)
            LookBrowser(catalog: model.catalog,
                        selectedID: model.currentLook.id,
                        thumbnails: model.lookThumbnails,
                        lockedIDs: model.lockedLookIDs,
                        favoriteIDs: Set(model.settings.favoriteLookIDs),
                        activeCategory: $model.activeCategory,
                        select: { look in withAnimation(animation) { model.select(look) } },
                        toggleFavorite: { model.toggleFavorite($0) })

            ProSlider(title: String(localized: "Strength"), value: $model.strength, range: 0...1, defaultValue: 1,
                      format: { "\(Int(($0 * 100).rounded()))" },
                      onEditingChanged: { model.interaction(began: $0) })
                .disabled(model.currentLook.isOriginal)
                .padding(.horizontal, 16)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                }
                if let guide = LookGuide.forLook(model.currentLook.id) {
                    Text(guide.bestFor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            if !model.hasPremiumNow && kind.isPremium {
                Text("Premium tool · preview free").font(.caption).foregroundStyle(Theme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoAdjustments.Kind.allCases) { tool in
                        AdjustToolButton(kind: tool, isSelected: model.adjustTool == tool,
                                         isChanged: abs(model.value(of: tool)) > 0.004,
                                         showsTitle: !dynamicTypeSize.isAccessibilitySize) {
                            model.adjustTool = tool
                        }
                        .frame(width: 64)
                    }
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
                    Label("Premium frames and layouts · preview free. The date stamp is free.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                LabeledContent("Frame") {
                    Picker("Frame", selection: $model.frame) {
                        ForEach(PhotoFinish.Frame.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .frame(minHeight: 44)
                if model.frame != .none {
                    ProSlider(title: String(localized: "Border"), value: $model.border, range: 0.01...0.16,
                              defaultValue: PhotoFinish().border, format: ProSlider.percent,
                              onEditingChanged: { model.interaction(began: $0) })
                }
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Layout") {
                        Picker("Export layout", selection: $model.exportLayout) {
                            ForEach(PhotoFinish.Layout.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .frame(minHeight: 44)
                    Text("Layouts fit your whole cropped photo inside the canvas.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Date stamp", isOn: $model.hasDateStamp)
                if model.hasDateStamp {
                    DatePicker("Date on photo", selection: $model.stampDate, displayedComponents: .date)
                    if model.isImported && model.record?.takenAt == nil {
                        Text("No capture date was found. Choose the date to print.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Remove All Finishing", role: .destructive) { model.resetFinish() }
                    .font(.subheadline)
                    .frame(minHeight: 44)
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

                Button {
                    showsExportOptions = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(PrimaryButtonStyle(isProminent: false))
                .frame(width: 56)
                .accessibilityLabel(Text("Export Options"))
                .accessibilityHint(Text("Format, size, quality and location, with the file size"))
            }
            .padding(.horizontal, 16)

            if model.offersFreeSave {
                // Never a dead end: the photo can always be saved without its
                // Premium parts.
                Button {
                    model.saveWithoutPremium()
                } label: {
                    HStack(spacing: 6) {
                        if model.isSavingFreeVersion {
                            ProgressView()
                        } else {
                            Image(systemName: model.isFreeVersionSaved ? "checkmark" : "square.and.arrow.down")
                        }
                        Text(model.freeSaveTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .minimumTapTarget()
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(model.isSavingFreeVersion || model.isSaving)
                .accessibilityHint(Text("Saves this photo to Photos for free. The full edit stays in Snapper."))
                Text("Free, keeping your crop and free edits. The full edit stays in Snapper.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else if model.savedCount > 0 && !model.hasPremiumNow {
                Button("Photo saved. Explore Premium styles", action: onShowPaywall)
                    .font(.caption.weight(.semibold))
            }

        }
        .animation(animation, value: model.isSaved)
        .animation(animation, value: model.isLocked)
        .animation(animation, value: model.offersFreeSave)
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
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .bloom: "Bloom"
        case .halation: "Halation"
        case .vignette: "Vignette"
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
        case .highlights: "sun.max.fill"
        case .shadows: "moon.fill"
        case .bloom: "sun.haze"
        case .halation: "sparkles"
        case .vignette: "circle.dashed"
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

/// Lays its content over the part of the canvas the photo really fills (the
/// photo is fitted and centred), so corner buttons sit on the photo rather
/// than floating in the empty space beside a wide or tall one.
private struct PhotoBoundsOverlay<Content: View>: View {
    let imageSize: CGSize?
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fittedRect(for: imageSize, in: geometry.size)
            ZStack { content }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    static func fittedRect(for imageSize: CGSize?, in bounds: CGSize) -> CGRect {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let aspect = imageSize.width / imageSize.height
        let size = bounds.width / bounds.height > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspect)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
