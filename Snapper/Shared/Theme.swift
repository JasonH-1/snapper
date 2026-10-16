import SwiftUI

/// Shared visual constants.
enum Theme {
    static let previewCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 20
    static let controlSize: CGFloat = 44

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

/// A round glass button used for camera controls.
struct CameraIconButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassSurface(in: Circle(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Primary call-to-action button (filled, full width).
struct PrimaryButtonStyle: ButtonStyle {
    var isProminent = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    /// Disabled buttons go grey so they never look tappable.
    private var foreground: Color {
        guard isEnabled else { return Color(.systemGray) }
        return isProminent ? .black : .primary
    }

    private var background: Color {
        isEnabled && isProminent ? Theme.accent : Color(.systemGray5)
    }
}

extension View {
    /// The pill for filter, category and shape chips. Selected is solid
    /// white; yellow is kept for primary actions so it always means "do it".
    /// The pill grows with the text size (padding, not a fixed height).
    func chip(isSelected: Bool, horizontalPadding: CGFloat = 12) -> some View {
        self
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .background {
                if isSelected {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.white.opacity(0.13))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                }
            }
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
