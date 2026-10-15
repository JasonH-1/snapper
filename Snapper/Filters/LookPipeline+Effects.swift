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
    /// seed always gives the same glitch slices, noise, grain, dust and leaks.
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
        if let halation = effects.halation {
            output = applyHalation(halation, strength: strength, unit: unit, to: output)
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
        if let leak = effects.lightLeak {
            output = applyLightLeak(leak, strength: strength, unit: unit, seed: seed, to: output)
        }
        if let scanlines = effects.scanlines {
            output = applyScanlines(scanlines, strength: strength, unit: unit, to: output)
        }
        if let noise = effects.noise {
            output = applyNoise(noise, strength: strength, unit: unit, seed: seed, to: output)
        }
        if let grain = effects.grain {
            output = applyGrain(grain, strength: strength, unit: unit, seed: seed, to: output)
        }
        if let dust = effects.dust {
            output = applyDust(dust, strength: strength, seed: seed, to: output)
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
        guard amount > 0.001, let placed = randomPattern(seed: seed, cell: CGSize(width: max(CGFloat(noise.size) * unit, 1),
                                                                                       height: max(CGFloat(noise.size) * unit, 1)),
                                                         in: image.extent) else { return image }
        let extent = image.extent

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

    /// Film halation: the brightest light gets a red halo with a tighter
    /// orange core (red spreads wider than green, and it is never blue).
    private static func applyHalation(_ halation: LookEffects.Halation, strength: CGFloat, unit: CGFloat,
                                      to image: CIImage) -> CIImage {
        let intensity = CGFloat(halation.intensity) * strength
        guard intensity > 0.001 else { return image }
        let extent = image.extent
        let threshold = CGFloat(min(max(halation.threshold, 0), 0.99))
        let gain = 1 / (1 - threshold)

        // Brightness above the threshold, as grey.
        let bright = CIFilter.colorMatrix()
        bright.inputImage = image
        let weights = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
        bright.rVector = weights
        bright.gVector = weights
        bright.bVector = weights
        bright.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        bright.biasVector = CIVector(x: -threshold * gain, y: -threshold * gain, z: -threshold * gain, w: 0)
        guard let source = clamped(bright.outputImage)?.clampedToExtent() else { return image }

        func blurred(_ radius: CGFloat) -> CIImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = source
            blur.radius = Float(max(radius, 0.5))
            return blur.outputImage?.cropped(to: extent) ?? source.cropped(to: extent)
        }
        let radius = CGFloat(halation.radius) * unit
        let red = channel(0, of: blurred(radius))
        let orange = scaled(channel(1, of: blurred(radius * 0.45)), by: 0.35)
        let none = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = scaled(combine(red, orange, none), by: intensity)
        screen.backgroundImage = image
        return screen.outputImage ?? image
    }

    /// Film burn: light that got into the camera. Full-height bands come in
    /// from the left, right or both edges, streak along the film and burn
    /// from deep red through orange to yellow and near-white where they are
    /// strongest. The seed decides the edges, how many bands, their widths,
    /// insets and peaks, and the streaks, so every photo's burn differs.
    private static func applyLightLeak(_ leak: LookEffects.LightLeak, strength: CGFloat, unit: CGFloat, seed: UInt64,
                                       to image: CIImage) -> CIImage {
        let intensity = CGFloat(leak.intensity) * strength
        guard intensity > 0.001 else { return image }
        let extent = image.extent
        var random = SeededGenerator(seed: mixedSeed(seed, 0x4C45_414B))
        let white = CIColor(red: 1, green: 1, blue: 1)
        let black = CIColor(red: 0, green: 0, blue: 0)

        // Left (4 in 10), right (4 in 10) or both edges.
        let sides = random.next() % 10
        let edges: [Bool] = sides < 4 ? [false] : sides < 8 ? [true] : [false, true]
        var field: CIImage?
        for fromRight in edges {
            for _ in 0..<(1 + Int(random.next() % 2)) {
                let width = extent.width * CGFloat(leak.size) * CGFloat.random(in: 0.5...1.3, using: &random)
                let inset = extent.width * CGFloat.random(in: 0...0.12, using: &random)
                let edgeX = fromRight ? extent.maxX - inset : extent.minX + inset
                // Across the frame: brightest at the edge, fading inwards.
                let across = CIFilter.linearGradient()
                across.point0 = CGPoint(x: edgeX, y: extent.midY)
                across.color0 = white
                across.point1 = CGPoint(x: edgeX + (fromRight ? -width : width), y: extent.midY)
                across.color1 = black
                // Along the edge: strongest somewhere up the side, never quite gone.
                let along = CIFilter.radialGradient()
                along.center = CGPoint(x: edgeX, y: extent.minY + extent.height * CGFloat.random(in: 0...1, using: &random))
                along.radius0 = 0
                along.radius1 = Float(extent.height * CGFloat.random(in: 0.6...1.2, using: &random))
                along.color0 = white
                along.color1 = CIColor(red: 0.3, green: 0.3, blue: 0.3)
                guard let acrossImage = across.outputImage?.cropped(to: extent),
                      let alongImage = along.outputImage?.cropped(to: extent) else { continue }
                let band = scaled(multiplied(acrossImage, alongImage), by: CGFloat.random(in: 0.6...1.0, using: &random))
                field = field.map { screened(band, over: $0) } ?? band
            }
        }
        guard var light = field else { return image }

        // The light smears along the film into soft vertical streaks: fine
        // and broad noise columns mixed, then softened sideways.
        let column = { (width: CGFloat, salt: UInt64) in
            randomPattern(seed: mixedSeed(seed, salt), cell: CGSize(width: max(width, 1), height: extent.height * 3), in: extent)
        }
        if let fine = column(unit * 0.006, 0x5354_524B), let broad = column(unit * 0.03, 0x5354_524C) {
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = fine
            mix.targetImage = broad
            mix.time = 0.5
            let soften = CIFilter.gaussianBlur()
            soften.inputImage = mix.outputImage?.clampedToExtent()
            soften.radius = Float(max(unit * 0.003, 0.5))
            let streaks = CIFilter.colorMatrix()
            streaks.inputImage = soften.outputImage?.cropped(to: extent)
            let row = CIVector(x: 0.5, y: 0, z: 0, w: 0)
            streaks.rVector = row
            streaks.gVector = row
            streaks.bVector = row
            streaks.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            streaks.biasVector = CIVector(x: 0.6, y: 0.6, z: 0.6, w: 0)
            if let lines = clamped(streaks.outputImage) { light = multiplied(light, lines) }
        }

        // Burn colour: stronger light burns hotter.
        let burn = CIFilter.colorMap()
        burn.inputImage = clamped(scaled(light, by: intensity))
        burn.gradientImage = burnRamp(hue: leak.tintHue)
        guard let burnt = clamped(burn.outputImage) else { return image }
        return screened(burnt, over: image)
    }

    /// A 256-step colour table for film burn (linear light): black, deep red,
    /// the tint (red-orange at the default hue), orange, yellow, pale yellow.
    private static func burnRamp(hue: Double) -> CIImage {
        let tint = LookEffects.tintColor(hue: hue)
        let peak = max(tint.r, tint.g, tint.b, 1e-6)
        let stops: [(at: Double, rgb: (Double, Double, Double))] = [
            (0, (0, 0, 0)),
            (0.25, (0.17, 0.007, 0.005)),
            (0.5, (0.8 * tint.r / peak, 0.8 * tint.g / peak, 0.8 * tint.b / peak)),
            (0.72, (1, 0.26, 0.02)),
            (0.88, (1, 0.72, 0.04)),
            (1, (1, 0.92, 0.4)),
        ]
        var floats: [Float] = []
        floats.reserveCapacity(256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255
            let upper = stops.firstIndex { $0.at >= t } ?? stops.count - 1
            let lower = max(upper - 1, 0)
            let span = max(stops[upper].at - stops[lower].at, 1e-6)
            let f = upper == lower ? 0 : (t - stops[lower].at) / span
            let a = stops[lower].rgb, b = stops[upper].rgb
            floats += [Float(a.0 + (b.0 - a.0) * f), Float(a.1 + (b.1 - a.1) * f), Float(a.2 + (b.2 - a.2) * f), 1]
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16, size: CGSize(width: 256, height: 1),
                       format: .RGBAf, colorSpace: nil)
    }

    private static func multiplied(_ a: CIImage, _ b: CIImage) -> CIImage {
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = a
        multiply.backgroundImage = b
        return multiply.outputImage ?? a
    }

    private static func screened(_ top: CIImage, over bottom: CIImage) -> CIImage {
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = top
        screen.backgroundImage = bottom
        return screen.outputImage ?? bottom
    }

    /// Film grain: fine and coarse noise mixed for clumping, mostly grey with
    /// a little colour, strongest in the mid-tones and shadows and faint in
    /// the highlights. Soft-light blended around 0.5, so it adds no cast.
    private static func applyGrain(_ grain: LookEffects.Grain, strength: CGFloat, unit: CGFloat, seed: UInt64,
                                   to image: CIImage) -> CIImage {
        let amount = CGFloat(grain.amount) * strength
        let extent = image.extent
        let cell = max(CGFloat(grain.size) * unit, 1)
        guard amount > 0.001,
              let fine = randomPattern(seed: mixedSeed(seed, 0x4752_4E31), cell: CGSize(width: cell, height: cell), in: extent),
              let coarse = randomPattern(seed: mixedSeed(seed, 0x4752_4E32),
                                         cell: CGSize(width: cell * 2.4, height: cell * 2.4), in: extent)
        else { return image }

        let mix = CIFilter.dissolveTransition()
        mix.inputImage = fine
        mix.targetImage = coarse
        mix.time = Float(min(max(grain.roughness, 0), 1) * 0.6)
        guard let mixed = mix.outputImage else { return image }

        // ±amount around 0.5; green and blue mix in their own noise for colour.
        let k = amount * 2
        let c = CGFloat(min(max(grain.color, 0), 1))
        let centred = CIFilter.colorMatrix()
        centred.inputImage = mixed
        centred.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        centred.gVector = CIVector(x: k * (1 - c), y: k * c, z: 0, w: 0)
        centred.bVector = CIVector(x: k * (1 - c), y: 0, z: k * c, w: 0)
        centred.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        centred.biasVector = CIVector(x: 0.5 - amount, y: 0.5 - amount, z: 0.5 - amount, w: 1)

        // Neutral 0.5 grey in the working space.
        let neutral = CIFilter.colorMatrix()
        neutral.inputImage = mixed
        neutral.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        neutral.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        neutral.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        neutral.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        neutral.biasVector = CIVector(x: 0.5, y: 0.5, z: 0.5, w: 1)

        // Where grain shows: sRGB luminance through a curve that peaks in the
        // lower mid-tones (≈1 at 0.4, 0.5 at black, 0.15 at white).
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let toSRGB = CIFilter.linearToSRGBToneCurve()
        toSRGB.inputImage = luma.outputImage
        let curve = CIFilter.colorPolynomial()
        curve.inputImage = toSRGB.outputImage
        let coefficients = CIVector(x: 0.5, y: 2.317, z: -2.667, w: 0)
        curve.redCoefficients = coefficients
        curve.greenCoefficients = coefficients
        curve.blueCoefficients = coefficients
        curve.alphaCoefficients = CIVector(x: 1, y: 0, z: 0, w: 0)

        let masked = CIFilter.blendWithMask()
        masked.inputImage = centred.outputImage?.cropped(to: extent)
        masked.backgroundImage = neutral.outputImage?.cropped(to: extent)
        masked.maskImage = clamped(curve.outputImage)?.cropped(to: extent)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = masked.outputImage
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    /// Film damage from the bundled textures (tools/lutgen/textures.py):
    /// dust in the red channel, hairs and long scratches in green, bands of
    /// horizontal scratches in blue, screened on in white. The seed picks the
    /// texture, flips it and moves it, so neighbouring frames differ.
    private static func applyDust(_ dust: LookEffects.Dust, strength: CGFloat, seed: UInt64,
                                  to image: CIImage) -> CIImage {
        let amount = CGFloat(min(max(dust.amount, 0), 1)) * strength
        let scratches = CGFloat(min(max(dust.scratches, 0), 1)) * strength
        let textures = FilmTextures.shared.dust
        guard amount > 0.001 || scratches > 0.001, !textures.isEmpty else { return image }
        let extent = image.extent
        var random = SeededGenerator(seed: mixedSeed(seed, 0x4455_5354))
        let texture = textures[Int(random.next() % UInt64(textures.count))]
        let size = texture.extent.size

        // Cover the photo with room to move, then flip and shift.
        let cover = max(extent.width / size.width, extent.height / size.height) * 1.15
        let flipX: CGFloat = random.next() & 1 == 1 ? -1 : 1
        let flipY: CGFloat = random.next() & 1 == 1 ? -1 : 1
        let placedWidth = size.width * cover, placedHeight = size.height * cover
        let dx = CGFloat.random(in: 0...(placedWidth - extent.width), using: &random)
        let dy = CGFloat.random(in: 0...(placedHeight - extent.height), using: &random)
        let placed = texture
            .transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
            .transformed(by: CGAffineTransform(scaleX: flipX * cover, y: flipY * cover))
            .transformed(by: CGAffineTransform(translationX: extent.minX + placedWidth / 2 - dx,
                                               y: extent.minY + placedHeight / 2 - dy))
            .cropped(to: extent)

        // Grey = dust × amount + (hairs + scratch bands) × scratches.
        let mix = CIFilter.colorMatrix()
        mix.inputImage = placed
        let row = CIVector(x: amount, y: scratches, z: scratches, w: 0)
        mix.rVector = row
        mix.gVector = row
        mix.bVector = row
        mix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let damage = clamped(mix.outputImage) else { return image }
        return screened(damage, over: image)
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

    /// Core Image's random pattern scaled to `cell` and made opaque. The
    /// generator always draws the same pattern, so the seed picks where to
    /// read it; its alpha is random too, so it is set to one to keep the
    /// colour values in 0…1 instead of being divided by a tiny alpha.
    private static func randomPattern(seed: UInt64, cell: CGSize, in extent: CGRect) -> CIImage? {
        guard let pattern = CIFilter.randomGenerator().outputImage else { return nil }
        let offsetX = CGFloat(seed % 4096)
        let offsetY = CGFloat((seed >> 12) % 4096)
        return pattern
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .transformed(by: CGAffineTransform(scaleX: cell.width, y: cell.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .settingAlphaOne(in: extent)
    }

    /// A separate seed per effect, so grain, dust and leaks don't line up.
    private static func mixedSeed(_ seed: UInt64, _ salt: UInt64) -> UInt64 {
        var random = SeededGenerator(seed: seed ^ salt)
        return random.next()
    }

    private static func clamped(_ image: CIImage?) -> CIImage? {
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage
    }

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

/// The bundled film-damage textures, loaded once. Their values are used as
/// they are (no colour management), like the effects' other grey masks.
private final class FilmTextures: @unchecked Sendable {
    static let shared = FilmTextures()

    let dust: [CIImage]

    private init() {
        dust = (1...8).compactMap { n in
            Bundle.main.url(forResource: "film-dust-\(n)", withExtension: "png")
                .flatMap { CIImage(contentsOf: $0, options: [.colorSpace: NSNull()]) }
        }
    }
}
