import SwiftUI

/// The Curves tab: an RGB curve and one per channel over the photo's
/// histogram. Tap the curve to add a point, drag a point to move it, drag it
/// off the top or bottom (or use Remove Point) to take it away.
struct CurvesPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.hasPremiumNow {
                Text("Premium curves · preview free").font(.caption).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 6) {
                ForEach(ToneCurves.Channel.allCases) { channel in
                    channelChip(channel)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Reset \(model.curveChannel.title) Curve", systemImage: "arrow.counterclockwise") {
                        model.resetCurve(model.curveChannel)
                    }
                    .disabled(model.curve(for: model.curveChannel).isIdentity)
                    Button("Reset All Curves", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
                        model.resetAllCurves()
                    }
                    .disabled(!model.recipe.adjustments.curves.isActive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.semibold))
                        .minimumTapTarget()
                }
                .accessibilityLabel(Text("Curve options"))
            }
            .padding(.horizontal, 16)

            CurveEditor(model: model)
                .frame(height: 176)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 2)
        .task(id: model.preview) { await model.refreshHistogram() }
    }

    private func channelChip(_ channel: ToneCurves.Channel) -> some View {
        let isSelected = model.curveChannel == channel
        let isChanged = !model.curve(for: channel).isIdentity
        return Button {
            model.curveChannel = channel
        } label: {
            HStack(spacing: 5) {
                Circle().fill(channel.color).frame(width: 8, height: 8)
                Text(channel.title)
                    .font(.footnote.weight(isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .chip(isSelected: isSelected, horizontalPadding: 10)
            .overlay(alignment: .topTrailing) {
                if isChanged {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 1, y: -1)
                }
            }
            .minimumTapTarget()
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
        .accessibilityLabel(Text("\(channel.title) curve"))
        .accessibilityValue(isChanged ? Text("Changed") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The curve graph itself.
private struct CurveEditor: View {
    @Bindable var model: EditorModel

    /// The point being dragged, where it was when the drag began, and
    /// whether letting go will remove it.
    @State private var dragIndex: Int?
    @State private var dragOrigin: CurvePoint?
    @State private var removesOnRelease = false
    @State private var selectedIndex: Int?

    /// How close (in points) a touch must be to grab a point.
    private static let grabRadius: CGFloat = 26
    /// How far past the top or bottom a point is dragged to remove it.
    private static let removeDistance: CGFloat = 34

    var body: some View {
        let channel = model.curveChannel
        let curve = model.curve(for: channel)
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(in: &context, size: size, curve: curve, channel: channel)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 1))

                if let index = selectedIndex, index > 0, index < curve.points.count - 1, dragIndex == nil {
                    let point = position(of: curve.points[index], in: size)
                    Button("Remove Point", systemImage: "minus.circle.fill") {
                        model.removeCurvePoint(at: index)
                        selectedIndex = nil
                    }
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                    .position(x: min(max(point.x, 60), size.width - 60), y: point.y > 40 ? point.y - 26 : point.y + 26)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size, curve: curve))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(channel.title) curve"))
            .accessibilityValue(Text(accessibilityDescription(curve)))
            .accessibilityHint(Text("Choose a point with the rotor actions, then swipe up or down to change its output."))
            .accessibilityAdjustableAction { direction in
                let index = selectedIndex ?? min(1, curve.points.count - 1)
                guard curve.points.indices.contains(index) else { return }
                var point = curve.points[index]
                point.y += direction == .increment ? 0.02 : -0.02
                model.interaction(began: true)
                model.moveCurvePoint(at: index, to: point)
                model.interaction(began: false)
                selectedIndex = index
            }
            .accessibilityActions {
                ForEach(Array(curve.points.indices), id: \.self) { index in
                    Button(pointName(index, of: curve)) { selectedIndex = index }
                }
                Button("Add point in the middle of the widest gap") {
                    if let index = addPointInWidestGap(curve) { selectedIndex = index }
                }
            }
        }
        .onChange(of: model.curveChannel) { _, _ in
            selectedIndex = nil
            dragIndex = nil
        }
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize, curve: ToneCurve) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let width = max(size.width, 1), height = max(size.height, 1)
                if dragIndex == nil {
                    model.interaction(began: true)
                    let start = value.startLocation
                    if let hit = nearestPoint(to: start, curve: curve, size: size) {
                        dragIndex = hit
                    } else {
                        // A new point sits on the curve; nothing changes until it's dragged.
                        let x = Double(min(max(start.x / width, 0), 1))
                        dragIndex = model.addCurvePoint(atInput: x)
                    }
                    selectedIndex = dragIndex
                    dragOrigin = dragIndex.map { model.curve(for: model.curveChannel).points[$0] }
                    return
                }
                guard let index = dragIndex, let origin = dragOrigin else { return }
                // The point follows the finger's movement, so grabbing it never makes it jump.
                let target = CurvePoint(x: origin.x + Double(value.translation.width / width),
                                        y: origin.y - Double(value.translation.height / height))
                let shownY = (1 - CGFloat(target.y)) * height
                let isEnd = index == 0 || index == model.curve(for: model.curveChannel).points.count - 1
                removesOnRelease = !isEnd && (shownY < -Self.removeDistance || shownY > height + Self.removeDistance)
                model.moveCurvePoint(at: index, to: target)
            }
            .onEnded { _ in
                if let index = dragIndex, removesOnRelease {
                    model.removeCurvePoint(at: index, asPartOfDrag: true)
                    selectedIndex = nil
                }
                dragIndex = nil
                dragOrigin = nil
                removesOnRelease = false
                model.interaction(began: false)
            }
    }

    private func nearestPoint(to location: CGPoint, curve: ToneCurve, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in curve.points.enumerated() {
            let position = position(of: point, in: size)
            let distance = hypot(position.x - location.x, position.y - location.y)
            if distance <= Self.grabRadius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func position(of point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
    }

    private func addPointInWidestGap(_ curve: ToneCurve) -> Int? {
        let points = curve.points
        guard points.count >= 2 else { return nil }
        var widest = 0
        for index in 0..<(points.count - 1) where points[index + 1].x - points[index].x > points[widest + 1].x - points[widest].x {
            widest = index
        }
        let x = (points[widest].x + points[widest + 1].x) / 2
        model.interaction(began: true)
        let index = model.addCurvePoint(atInput: x)
        model.interaction(began: false)
        return index
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, curve: ToneCurve, channel: ToneCurves.Channel) {
        // Histogram of the edited photo, so it's clear where the tones are.
        let histogram = model.histogram
        if histogram.count > 1 {
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in histogram.enumerated() {
                let x = CGFloat(index) / CGFloat(histogram.count - 1) * size.width
                shape.addLine(to: CGPoint(x: x, y: size.height - CGFloat(value) * size.height * 0.85))
            }
            shape.addLine(to: CGPoint(x: size.width, y: size.height))
            shape.closeSubpath()
            context.fill(shape, with: .color(.white.opacity(0.1)))
        }

        // Quarter grid and the unchanged diagonal.
        var grid = Path()
        for step in 1..<4 {
            let x = size.width * CGFloat(step) / 4, y = size.height * CGFloat(step) / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

        // The other channels' curves, faintly, when they're changed.
        for other in ToneCurves.Channel.allCases where other != channel {
            let otherCurve = model.curve(for: other)
            guard !otherCurve.isIdentity else { continue }
            context.stroke(path(for: otherCurve, in: size), with: .color(other.color.opacity(0.35)), lineWidth: 1)
        }

        context.stroke(path(for: curve, in: size), with: .color(channel.color), lineWidth: 2)

        for (index, point) in curve.points.enumerated() {
            let center = position(of: point, in: size)
            let isActive = index == dragIndex || index == selectedIndex
            let radius: CGFloat = isActive ? 7 : 5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            if index == dragIndex && removesOnRelease {
                context.stroke(dot, with: .color(.red), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(isActive ? Theme.accent : .white))
                context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    private func path(for curve: ToneCurve, in size: CGSize) -> Path {
        let samples = max(Int(size.width / 3), 32)
        let values = curve.table(count: samples)
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) / CGFloat(samples - 1) * size.width,
                                y: (1 - CGFloat(value)) * size.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    // MARK: - Accessibility

    private func pointName(_ index: Int, of curve: ToneCurve) -> String {
        let point = curve.points[index]
        return String(localized: "Point \(index + 1): input \(Int((point.x * 100).rounded())), output \(Int((point.y * 100).rounded()))")
    }

    private func accessibilityDescription(_ curve: ToneCurve) -> String {
        if curve.isIdentity { return String(localized: "Unchanged") }
        return curve.points.indices.map { pointName($0, of: curve) }.joined(separator: "; ")
    }
}

/// Split toning, in the Color tab: one tint for the highlights, another for
/// the shadows, and the balance between them.
struct SplitToningPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toneRow(title: Text("Highlights"), hue: \.highlightHue, saturation: \.highlightSaturation)
            toneRow(title: Text("Shadows"), hue: \.shadowHue, saturation: \.shadowSaturation)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Balance").font(.caption)
                    Spacer()
                    Text(EditorView.formatAdjustment(model.splitToning.balance))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: binding(\.balance), in: -1...1, onEditingChanged: { model.interaction(began: $0) })
                    .tint(Theme.accent)
                    .accessibilityLabel(Text("Balance"))
                    .accessibilityValue(Text(balanceDescription))
            }
            Button("Reset Split Toning") { model.resetSplitToning() }
                .frame(minHeight: 44)
                .disabled(model.splitToning == .none)
        }
    }

    private func toneRow(title: Text, hue: WritableKeyPath<SplitToning, Double>,
                         saturation: WritableKeyPath<SplitToning, Double>) -> some View {
        let toning = model.splitToning
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hue: toning[keyPath: hue] / 360, saturation: max(toning[keyPath: saturation], 0.15), brightness: 1))
                    .frame(width: 12, height: 12)
                title.font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(toning[keyPath: hue].rounded()))° · \(Int((toning[keyPath: saturation] * 100).rounded()))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HueSlider(value: binding(hue), onEditingChanged: { model.interaction(began: $0) })
                .accessibilityLabel(title)
                .accessibilityValue(Text("Hue \(Int(toning[keyPath: hue].rounded())) degrees"))
            Slider(value: binding(saturation), in: 0...1, onEditingChanged: { model.interaction(began: $0) })
                .tint(Color(hue: toning[keyPath: hue] / 360, saturation: 0.8, brightness: 1))
                .accessibilityLabel(title)
                .accessibilityValue(Text("Saturation \(Int((toning[keyPath: saturation] * 100).rounded())) percent"))
        }
    }

    private var balanceDescription: String {
        let value = model.splitToning.balance
        if abs(value) < 0.01 { return String(localized: "Even") }
        let amount = Int((abs(value) * 100).rounded())
        return value > 0 ? String(localized: "Favours highlights by \(amount)") : String(localized: "Favours shadows by \(amount)")
    }

    private func binding(_ key: WritableKeyPath<SplitToning, Double>) -> Binding<Double> {
        Binding(get: { model.splitToning[keyPath: key] }, set: { value in
            var toning = model.splitToning
            toning[keyPath: key] = value
            model.splitToning = toning
        })
    }
}

/// A hue slider over a rainbow track.
private struct HueSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        Slider(value: $value, in: 0...360, onEditingChanged: onEditingChanged)
            .tint(.clear)
            .background {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.85, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 6)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
            }
    }
}

extension ToneCurves.Channel {
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: String(localized: "Red")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        }
    }

    var color: Color {
        switch self {
        case .rgb: .white
        case .red: Color(red: 1, green: 0.36, blue: 0.33)
        case .green: Color(red: 0.35, green: 0.85, blue: 0.4)
        case .blue: Color(red: 0.35, green: 0.6, blue: 1)
        }
    }
}
