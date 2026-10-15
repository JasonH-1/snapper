import CoreImage
import CoreImage.CIFilterBuiltins

/// The texture-and-light half of a look, drawn after the colour LUT with
/// built-in Core Image filters only.
extension LookPipeline {
    /// Applies a whole look: its LUT at `strength`, then its effects.
    static func apply(_ look: Look, lut: CubeLUT?, strength: Float = 1, seed: UInt64 = 0, to image: CIImage) -> CIImage {
        let graded = apply(lut, strength: strength, to: image)
        return applyEffects(look.effects, strength: strength, seed: seed, to: graded)
    }

    /// Applies `effects` to an already graded image.
    ///
    /// Lengths scale with the image's shorter side and `strength` scales every
    /// effect, so the live preview, the review screen's slider and a
    /// full-resolution export agree. `seed` fixes the random parts: the same
    /// seed always gives the same glitch slices and noise.
    static func applyEffects(_ effects: LookEffects, strength: Float = 1, seed: UInt64 = 0, to image: CIImage) -> CIImage {
        let extent = image.extent
        let strength = CGFloat(strength)
        guard !effects.isEmpty, strength > 0.001, !extent.isInfinite,
              extent.width >= 2, extent.height >= 2 else { return image }
        let unit = min(extent.width, extent.height)

        var output = image
        if let gradient = effects.gradient {
            output = applyGradient(gradient, strength: strength, to: output)
        }
        if let glow = effects.glow {
            output = applyGlow(glow, strength: strength, unit: unit, to: output)
        }
        if let aberration = effects.chromaticAberration {
            output = applyChromaticAberration(aberration, strength: strength, to: output)
        }
        if let bleed = effects.chromaBleed {
            output = applyChromaBleed(bleed, strength: strength, unit: unit, to: output)
        }
        if let glitch = effects.glitch {
            var random = SeededGenerator(seed: seed)
            output = applyGlitch(glitch, strength: strength, unit: unit, random: &random, to: output)
        }
        if let scanlines = effects.scanlines {
            output = applyScanlines(scanlines, strength: strength, unit: unit, to: output)
        }
        if let noise = effects.noise {
            output = applyNoise(noise, strength: strength, unit: unit, seed: seed, to: output)
        }
        if let vignette = effects.vignette {
            output = applyVignette(vignette, strength: strength, to: output)
        }
        return output.cropped(to: extent)
    }

    // MARK: - Effects

    /// A graduated filter from the top edge: the top of the frame is
    /// brightened and pulled towards the tint colour, fading out at `size`
    /// of the height (Lightroom's linear gradient).
    private static func applyGradient(_ gradient: LookEffects.Gradient, strength: CGFloat, to image: CIImage) -> CIImage {
        let exposure = CGFloat(gradient.exposure) * strength
        let tint = CGFloat(min(max(gradient.tint, 0), 1)) * strength
        guard exposure > 0.001 || tint > 0.001 else { return image }
        let extent = image.extent

        // Per-channel gains: brighter, and towards a unit-luminance tint colour.
        let gain = pow(2, exposure)
        let color = LookEffects.tintColor(hue: gradient.tintHue)
        let adjust = CIFilter.colorMatrix()
        adjust.inputImage = image
        adjust.rVector = CIVector(x: gain * (1 - tint + tint * CGFloat(color.r)), y: 0, z: 0, w: 0)
        adjust.gVector = CIVector(x: 0, y: gain * (1 - tint + tint * CGFloat(color.g)), z: 0, w: 0)
        adjust.bVector = CIVector(x: 0, y: 0, z: gain * (1 - tint + tint * CGFloat(color.b)), w: 0)
        adjust.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        // White at the top edge, black at `size` of the height.
        let size = CGFloat(min(max(gradient.size, 0.01), 1))
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        ramp.color0 = CIColor(red: 1, green: 1, blue: 1)
        ramp.point1 = CGPoint(x: extent.midX, y: extent.maxY - size * extent.height)
        ramp.color1 = CIColor(red: 0, green: 0, blue: 0)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjust.outputImage
        blend.backgroundImage = image
        blend.maskImage = ramp.outputImage?.cropped(to: extent)
        return blend.outputImage ?? image
    }

    /// Keeps only light above the threshold, in its own (more saturated)
    /// colour, optionally pulled towards a tint, blurs it and screens it back
    /// over the image.
    private static func applyGlow(_ glow: LookEffects.Glow, strength: CGFloat, unit: CGFloat, to image: CIImage) -> CIImage {
        let extent = image.extent
        let threshold = CGFloat(min(max(glow.threshold, 0), 0.99))
        let gain = 1 / (1 - threshold)

        let highlights = CIFilter.colorMatrix()
        highlights.inputImage = image
        highlights.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        highlights.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        highlights.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        highlights.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        highlights.biasVector = CIVector(x: -threshold * gain, y: -threshold * gain, z: -threshold * gain, w: 0)

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = highlights.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        let saturate = CIFilter.colorControls()
        saturate.inputImage = clamp.outputImage
        saturate.saturation = Float(glow.saturation)

        guard let saturated = saturate.outputImage else { return image }
        let colored = glow.tint > 0.001
            ? tinted(saturated, hue: glow.tintHue, amount: CGFloat(min(glow.tint, 1)))
            : saturated

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = colored.clampedToExtent()
        blur.radius = Float(CGFloat(glow.radius) * unit)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = scaled(blurred, by: CGFloat(glow.intensity) * strength)
        screen.backgroundImage = image
        return screen.outputImage ?? image
    }

    /// Scales red up and blue down around the centre, so the fringes grow
    /// towards the edges like a real lens.
    private static func applyChromaticAberration(_ aberration: LookEffects.ChromaticAberration,
                                                 strength: CGFloat, to image: CIImage) -> CIImage {
        let amount = CGFloat(aberration.amount) * strength
        guard amount > 0 else { return image }
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let source = image.clampedToExtent()
        let red = channel(0, of: source).transformed(by: scale(1 + amount, around: center))
        let blue = channel(2, of: source).transformed(by: scale(1 - amount, around: center))
        return combine(red, channel(1, of: source), blue).cropped(to: extent)
    }

    /// Smears colour sideways while brightness stays sharp, like videotape.
    private static func applyChromaBleed(_ bleed: LookEffects.ChromaBleed, strength: CGFloat,
                                         unit: CGFloat, to image: CIImage) -> CIImage {
        let radius = CGFloat(bleed.radius) * unit * strength
        guard radius > 0.5 else { return image }
        let blur = CIFilter.motionBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius)
        blur.angle = 0
        // Colour blend: hue and saturation from the smear, luminance from the original.
        let color = CIFilter.colorBlendMode()
        color.inputImage = blur.outputImage?.cropped(to: image.extent)
        color.backgroundImage = image
        return color.outputImage ?? image
    }

    /// Pulls red and blue apart, then pushes a few horizontal slices sideways.
    /// Slice positions come from `random`, so they never depend on `strength`.
    private static func applyGlitch(_ glitch: LookEffects.Glitch, strength: CGFloat, unit: CGFloat,
                                    random: inout SeededGenerator, to image: CIImage) -> CIImage {
        let extent = image.extent
        var output = image

        let split = CGFloat(glitch.rgbSplit) * unit * strength
        if split > 0.25 {
            let source = image.clampedToExtent()
            let red = channel(0, of: source).transformed(by: CGAffineTransform(translationX: -split, y: 0))
            let blue = channel(2, of: source).transformed(by: CGAffineTransform(translationX: split, y: 0))
            output = combine(red, channel(1, of: source), blue).cropped(to: extent)
        }

        let maxShift = CGFloat(glitch.shift) * extent.width * strength
        let base = output.clampedToExtent()
        for _ in 0..<max(glitch.slices, 0) {
            let height = extent.height * CGFloat.random(in: 0.004...0.05, using: &random)
            let y = extent.minY + CGFloat.random(in: 0...(extent.height - height), using: &random)
            let dx = maxShift * CGFloat.random(in: -1...1, using: &random)
            guard abs(dx) > 0.25 else { continue }
            let slice = base
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .cropped(to: CGRect(x: extent.minX, y: y, width: extent.width, height: height))
            output = slice.composited(over: output)
        }
        return output
    }

    /// Darkens evenly spaced horizontal lines.
    private static func applyScanlines(_ scanlines: LookEffects.Scanlines, strength: CGFloat,
                                       unit: CGFloat, to image: CIImage) -> CIImage {
        let alpha = min(CGFloat(scanlines.intensity) * strength, 1)
        guard alpha > 0.001 else { return image }
        let extent = image.extent
        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: extent.minX, y: extent.minY)
        stripes.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: alpha)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        // One dark and one clear stripe per line.
        stripes.width = Float(max(CGFloat(scanlines.spacing) * unit, 2) / 2)
        stripes.sharpness = 0.6
        guard let vertical = stripes.outputImage else { return image }
        let horizontal = vertical.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        return horizontal.cropped(to: extent).composited(over: image)
    }

    /// Adds fine grey noise, soft-light blended so mid-tones carry most of it.
    private static func applyNoise(_ noise: LookEffects.Noise, strength: CGFloat, unit: CGFloat,
                                   seed: UInt64, to image: CIImage) -> CIImage {
        let amount = CGFloat(noise.amount) * strength
        guard amount > 0.001, let pattern = CIFilter.randomGenerator().outputImage else { return image }
        let extent = image.extent
        // The generator always draws the same pattern; the seed picks where to read it.
        let offsetX = CGFloat(seed % 4096)
        let offsetY = CGFloat((seed >> 12) % 4096)
        let cell = max(CGFloat(noise.size) * unit, 1)
        // The generator's alpha is random too; make it opaque so its colour
        // values stay in 0…1 instead of being divided by a tiny alpha.
        let placed = pattern
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .settingAlphaOne(in: extent)

        // Grey centred on 0.5, which soft light leaves unchanged.
        let grey = CIFilter.colorMatrix()
        grey.inputImage = placed
        let k = amount * 2
        grey.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        grey.gVector = CIVector(x: k, y: 0, z: 0, w: 0)
        grey.bVector = CIVector(x: k, y: 0, z: 0, w: 0)
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        grey.biasVector = CIVector(x: 0.5 - amount, y: 0.5 - amount, z: 0.5 - amount, w: 1)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grey.outputImage?.cropped(to: extent)
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    private static func applyVignette(_ vignette: LookEffects.Vignette, strength: CGFloat, to image: CIImage) -> CIImage {
        let extent = image.extent
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(CGFloat(vignette.radius) * hypot(extent.width, extent.height) / 2)
        filter.intensity = Float(CGFloat(vignette.intensity) * strength)
        filter.falloff = 0.5
        return filter.outputImage ?? image
    }

    // MARK: - Helpers

    /// One colour channel (0 red, 1 green, 2 blue); the other two are zero.
    private static func channel(_ index: Int, of image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: index == 0 ? 1 : 0, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: index == 1 ? 1 : 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: index == 2 ? 1 : 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    /// Puts single-channel images back together: each is zero in the other
    /// two channels, so the per-component maximum recombines them.
    private static func combine(_ red: CIImage, _ green: CIImage, _ blue: CIImage) -> CIImage {
        let redGreen = CIFilter.maximumCompositing()
        redGreen.inputImage = red
        redGreen.backgroundImage = green
        let all = CIFilter.maximumCompositing()
        all.inputImage = blue
        all.backgroundImage = redGreen.outputImage
        return all.outputImage ?? green
    }

    /// Mixes each pixel towards its own luminance in the tint colour, so
    /// white light takes on the tint while keeping its brightness.
    private static func tinted(_ image: CIImage, hue: Double, amount: CGFloat) -> CIImage {
        let color = LookEffects.tintColor(hue: hue)
        let tint = [CGFloat(color.r), CGFloat(color.g), CGFloat(color.b)]
        let weights: [CGFloat] = [0.2126, 0.7152, 0.0722]
        func row(_ channel: Int) -> CIVector {
            let mixed = (0..<3).map { amount * tint[channel] * weights[$0] + ($0 == channel ? 1 - amount : 0) }
            return CIVector(x: mixed[0], y: mixed[1], z: mixed[2], w: 0)
        }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = row(0)
        matrix.gVector = row(1)
        matrix.bVector = row(2)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    private static func scaled(_ image: CIImage, by factor: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    private static func scale(_ factor: CGFloat, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -center.x, y: -center.y)
    }
}
