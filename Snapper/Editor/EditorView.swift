import SwiftUI

/// Edits one Library photo: Looks, Adjust and Crop tabs over the photo, with
/// Share and Save at the bottom. Pushed from the Library.
struct EditorView: View {
    @Bindable var model: EditorModel
    var onShowPaywall: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 12) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabSwitcher(selection: $model.tab)
                .padding(.horizontal, 16)
            panel
            actions
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { showResetConfirmation = true }
                    .disabled(!model.isEdited)
            }
        }
        .confirmationDialog("Reset all edits?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Edits", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) { model.reset() }
            }
        } message: {
            Text(model.isImported
                 ? "The look, light and colour, and crop go back to how the photo was imported."
                 : "The look, light and colour, and crop go back to how the photo was taken.")
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
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
        .onDisappear { model.finish() }
    }

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

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        if model.tab == .crop {
            if let base = model.cropBase {
                CropCanvas(image: base, straighten: model.straighten, rect: model.cropRect, aspect: model.cropAspect) { rect in
                    model.setCropRect(rect)
                }
                .transition(.opacity)
            } else {
                ProgressView()
            }
        } else {
            ZStack {
                if let image = model.displayImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16)
                        .accessibilityLabel(Text("Photo in \(model.currentLook.name)"))
                } else {
                    ProgressView()
                }
                if model.isShowingOriginal {
                    VStack {
                        Text("Original")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassSurface(in: Capsule())
                            .padding(.top, 10)
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                model.isShowingOriginal = pressing
            })
            .accessibilityHint(Text("Touch and hold to compare with the original."))
        }
    }

    // MARK: - Panels

    @ViewBuilder
    private var panel: some View {
        switch model.tab {
        case .looks: looksPanel
        case .adjust: adjustPanel
        case .crop: cropPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 12) {
            LookBrowser(catalog: model.catalog,
                        selectedID: model.currentLook.id,
                        thumbnails: model.lookThumbnails,
                        lockedIDs: model.lockedLookIDs,
                        favoriteIDs: Set(model.settings.favoriteLookIDs),
                        activeCategory: $model.activeCategory,
                        select: { model.select($0) },
                        toggleFavorite: { model.toggleFavorite($0) })

            HStack(spacing: 12) {
                Text("Strength")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: $model.strength, in: 0...1)
                    .disabled(model.currentLook.isOriginal)
                Text("\(Int((model.strength * 100).rounded()))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .opacity(model.currentLook.isOriginal ? 0.4 : 1)
        }
    }

    private var adjustPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(PhotoAdjustments.Kind.allCases) { kind in
                    AdjustToolButton(kind: kind, isSelected: model.adjustTool == kind,
                                     isChanged: abs(model.value(of: kind)) > 0.004) {
                        model.adjustTool = kind
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            let kind = model.adjustTool
            VStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.resetValue(of: kind) }
                } label: {
                    Text(Self.formatAdjustment(model.value(of: kind)))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(abs(model.value(of: kind)) > 0.004 ? Theme.accent : .white)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Reset \(String(localized: kind.title))"))

                RulerSlider(value: Binding(get: { model.value(of: kind) }, set: { model.setValue($0, for: kind) }),
                            range: kind.range, tickStep: 0.05)
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .id(kind)
                    .accessibilityLabel(Text(kind.title))
            }
        }
        .padding(.vertical, 6)
    }

    private var cropPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(CropShape.allCases) { shape in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.setShape(shape) }
                    } label: {
                        Text(shape.title)
                            .font(.footnote.weight(model.recipe.crop.shape == shape ? .bold : .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .foregroundStyle(model.recipe.crop.shape == shape ? Color.black : Color.white)
                            .background {
                                if model.recipe.crop.shape == shape {
                                    Capsule().fill(Theme.accent)
                                } else {
                                    Capsule().fill(.white.opacity(0.13))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.recipe.crop.shape == shape ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.rotate() }
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text("Rotate 90 degrees"))

                VStack(spacing: 5) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { model.straighten = 0 }
                    } label: {
                        Text("\(Self.formatDegrees(model.straighten)) Straighten")
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .foregroundStyle(abs(model.straighten) > 0.05 ? Theme.accent : .white)
                    }
                    .buttonStyle(.plain)
                    RulerSlider(value: $model.straighten, range: PhotoCrop.straightenRange, tickStep: 1, spacing: 8)
                        .frame(height: 24)
                        .accessibilityLabel(Text("Straighten"))
                }

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.flip() }
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text("Flip horizontally"))
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.share()
                } label: {
                    Label {
                        Text("Share")
                    } icon: {
                        if model.isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isProminent: false))
                .frame(width: 120)

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
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isSaving)
            }
            .padding(.horizontal, 16)

            if model.showsWatermarkNote {
                HStack(spacing: 6) {
                    Image(systemName: "seal")
                    Text("Free exports include a small watermark.")
                    Button("Remove", action: onShowPaywall)
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isSaved)
        .animation(.easeInOut(duration: 0.2), value: model.isLocked)
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

/// The Looks | Adjust | Crop switch.
private struct TabSwitcher: View {
    @Binding var selection: EditorModel.Tab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 3) {
            ForEach(EditorModel.Tab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(selection == tab ? .bold : .semibold))
                        .foregroundStyle(selection == tab ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selection == tab {
                                Capsule().fill(Theme.accent)
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// One slider in the Adjust tab: a round icon and its name, with a dot when
/// it has been moved.
private struct AdjustToolButton: View {
    let kind: PhotoAdjustments.Kind
    let isSelected: Bool
    let isChanged: Bool
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
                            Circle().fill(Theme.accent)
                        } else {
                            Circle().fill(.white.opacity(0.13))
                                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isChanged && !isSelected {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                                .offset(x: 1, y: -1)
                        }
                    }
                Text(kind.title)
                    .font(.caption2.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
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
