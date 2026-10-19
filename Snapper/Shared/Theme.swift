import SwiftUI

/// Shared visual constants.
enum Theme {
    static let previewCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 20
    static let controlSize: CGFloat = 44
    static let canvas = Color(red: 0.065, green: 0.066, blue: 0.073)
    static let surface = Color(red: 0.115, green: 0.117, blue: 0.13)

    /// Look names are set in the serif face for a printed, editorial feel.
    static func lookTitle(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }

    /// A look name in the serif at a text style, so it follows Dynamic Type.
    static func lookName(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    /// Signal yellow (the AccentColor asset). Fills carry black content; as a
    /// text or icon colour it needs a dark surface, which is why the app is
    /// dark-only.
    static let accent = Color.accentColor
}

extension View {
    /// Liquid Glass behind this view on iOS 26 and later; a frosted material
    /// (or a solid tint) on earlier versions. `tint` colours the glass, for
    /// selected controls.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @available(iOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - Controls

/// Controls take after the camera's dial: dark faces, hairline edges where
/// a button needs an outline, and Signal Yellow only for the primary action.
/// Nothing glows except the purchase button.
enum Instrument {
    static let hairline = Color.white.opacity(0.18)
    static let face = Color.white.opacity(0.05)
    static let pressedFace = Color.white.opacity(0.12)
    /// Camera and editing controls: a borderless face a little lighter
    /// than `face`, so it reads over the black camera chrome.
    static let controlFace = Color.white.opacity(0.1)
    static let pressedControlFace = Color.white.opacity(0.2)
}

/// A square camera or editing control on a borderless dark face.
struct CameraIconButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .controlFace(isPressed: configuration.isPressed)
            .contentShape(Rectangle())
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Call-to-action button, full width: yellow, or a hairline outline when
/// not prominent. `glows` is for the purchase button only.
struct PrimaryButtonStyle: ButtonStyle {
    var isProminent = true
    var glows = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let isPressed = configuration.isPressed && isEnabled
        let isFilled = isProminent && isEnabled
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(isEnabled ? (isProminent ? Color.black : Color.white) : Color(.systemGray))
            .background {
                if isFilled {
                    shape.fill(isPressed ? Color(red: 0.9, green: 0.72, blue: 0) : Theme.accent)
                } else {
                    shape.fill(isPressed ? Instrument.pressedFace : Instrument.face)
                }
            }
            .overlay {
                if !isFilled {
                    shape.strokeBorder(isEnabled ? Instrument.hairline : Color.white.opacity(0.08), lineWidth: 1)
                }
            }
            .shadow(color: Theme.accent.opacity(glows && isFilled && !isPressed ? 0.3 : 0), radius: 14)
            .animation(Motion.quick, value: isPressed)
    }
}

extension View {
    /// A camera or editing control's face: dark and borderless, lighter
    /// while pressed.
    func controlFace(isPressed: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        background(isPressed ? Instrument.pressedControlFace : Instrument.controlFace,
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A secondary button's face: dark, with a hairline edge.
    func hairlineControl(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Instrument.face, in: shape)
            .overlay(shape.strokeBorder(Instrument.hairline, lineWidth: 1))
    }

    /// The chip for filters, categories and shapes: a hairline frame,
    /// brighter and outlined in white when selected. Yellow is kept for the
    /// primary action. The chip grows with the text size (padding, not a
    /// fixed height).
    func chip(isSelected: Bool, horizontalPadding: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return self
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.75))
            .background(isSelected ? Color.white.opacity(0.14) : Instrument.face, in: shape)
            .overlay(shape.strokeBorder(isSelected ? Color.white.opacity(0.75) : Instrument.hairline, lineWidth: 1))
    }

    /// Pads a small control's tappable area out to Apple's 44 pt minimum
    /// without changing how it looks.
    func minimumTapTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension Animation {
    /// `animation`, or none when Reduce Motion is on (state still changes,
    /// just without movement).
    static func snapper(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Motion tokens, after Apple's spring guidance: critically damped (no
/// overshoot) for UI changes; a little bounce only where a turn implies
/// momentum.
enum Motion {
    /// Most UI: tabs, chips, panels, the crop box settling.
    static let standard = Animation.smooth(duration: 0.35)
    static let quick = Animation.smooth(duration: 0.2)
    /// A quarter turn: Apple's rotation spring (damping 0.8, response 0.4).
    static let turn = Animation.spring(response: 0.4, dampingFraction: 0.8)

    /// How far a drag past an edge actually moves: the further past, the less
    /// it follows, like stretching something real.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }
}

/// Feedback the instant a finger lands: a slight press-in, released when
/// the finger lifts or slides off.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension View {
    /// Marks this view as where a zoom transition starts and ends (iOS 18+).
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18, *), let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Presents this view growing out of (and shrinking back into) its
    /// source, which also lets it be swiped down to close (iOS 18+).
    @ViewBuilder
    func zoomTransition(from id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18, *), let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
