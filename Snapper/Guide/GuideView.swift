import SwiftUI

/// A standalone, offline reference. Examples never write to the photo library.
struct GuideView: View {
    let library: LookLibrary
    let onOpen: ((GuideDestination) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path: [String]

    init(library: LookLibrary, initialTopicID: String? = nil,
         onOpen: ((GuideDestination) -> Void)? = nil) {
        self.library = library
        self.onOpen = onOpen
        _path = State(initialValue: initialTopicID.flatMap { id in
            GuideCatalog.topics.contains { $0.id == id } ? [id] : nil
        } ?? [])
    }

    private var results: [GuideTopic] { GuideCatalog.search(query) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("A little guidance. Better photos.", systemImage: "sparkles")
                                .font(Theme.lookName(.title2))
                            Text("Start with your first photo, or explore a tool. Visual examples use a sample photo and never change your own images.")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }
                ForEach(GuideCatalog.sections, id: \.self) { section in
                    let topics = results.filter { $0.section == section }
                    if !topics.isEmpty {
                        Section(section) {
                            ForEach(topics) { topic in
                                NavigationLink(value: topic.id) {
                                    Label {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(topic.title).font(.headline)
                                            Text(topic.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }.padding(.vertical, 5)
                                    } icon: {
                                        Image(systemName: topic.symbol).foregroundStyle(Theme.accent).frame(width: 28)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let topic = GuideCatalog.topics.first(where: { $0.id == id }) {
                    GuideTopicView(topic: topic, library: library, onOpen: onOpen)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search filters, white balance, saving…")
            .navigationTitle("Snapper Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct GuideTopicView: View {
    let topic: GuideTopic
    let library: LookLibrary
    let onOpen: ((GuideDestination) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(topic.section.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                Text(topic.title).font(Theme.lookName(.largeTitle)).accessibilityAddTraits(.isHeader)
                Text(topic.summary).font(.title3).foregroundStyle(.secondary)
                if [.looks, .brightness, .warmth, .crop].contains(topic.visual) {
                    GuidePhotoExample(visual: topic.visual, library: library)
                } else {
                    GuideDiagram(visual: topic.visual)
                }
                Text("Try it step by step").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
                            .frame(minWidth: 26)
                        Text(step).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityElement(children: .combine)
                }
                Label(topic.note, systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                if let destination = topic.destination, let onOpen {
                    Button { onOpen(destination) } label: {
                        Label(destination.buttonTitle, systemImage: "arrow.up.right")
                    }.buttonStyle(PrimaryButtonStyle())
                    Text("Closes the guide and opens \(destination.screenName). No photo is taken or changed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(Theme.canvas)
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension GuideDestination {
    var buttonTitle: String {
        switch self {
        case .camera: "Open Camera"
        case .looks: "Explore Looks"
        case .library: "Open Library"
        case .styles: "Open My Styles"
        }
    }
    var screenName: String {
        switch self {
        case .camera: "the camera"
        case .looks: "Looks"
        case .library: "Library; tap a photo to edit it"
        case .styles: "My Styles"
        }
    }
}

/// Labeled illustrations, not screenshots. No animation is required to understand them.
private struct GuideDiagram: View {
    let visual: GuideVisual
    private var items: [(String, String, String)] {
        switch visual {
        case .camera:
            [("viewfinder", "1. Frame & focus", "Tap your subject in the preview."),
             ("slider.horizontal.3", "2. Camera Options", "Adjust exposure, focus and white balance where supported."),
             ("circle.inset.filled", "3. Shutter", "Take the photo, then open Library to edit.")]
        case .style:
            [("camera.filters", "Look + strength", "Choose the filter and how strongly it appears."),
             ("slider.horizontal.3", "Adjustments", "Save the light, color, fade and grain settings."),
             ("square.stack", "Reusable style", "Apply to another photo. Crop and frames stay separate.")]
        default:
            [("photo.on.rectangle", "Snapper Library", "Your original plus editable settings."),
             ("slider.horizontal.3", "Edit & finish", "Change the look, crop or add a frame."),
             ("square.and.arrow.up", "Save or Share", "Create an edited copy for Photos or another destination.")]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("HOW IT WORKS").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            ForEach(items, id: \.1) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.0).font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.1).font(.headline)
                        Text(item.2).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Uses the app's real rendering pipeline, a bundled image, and an isolated renderer/cache.
private struct GuidePhotoExample: View {
    let visual: GuideVisual
    let library: LookLibrary
    @State private var amount = 0.6
    @State private var original: UIImage?
    @State private var edited: UIImage?
    @State private var failed = false
    @State private var renderer = PhotoRenderer()
    @State private var sampleID = UUID()

    private var look: Look {
        visual == .looks ? (library.looks.first { !$0.isPremium && $0.id != Look.original.id } ?? .original) : .original
    }
    private var controlTitle: String {
        switch visual {
        case .looks: "Look strength"
        case .brightness: "Brightness"
        case .warmth: "Warmth"
        default: "Square crop"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXPLORE ON A SAMPLE PHOTO").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            if let original, let edited {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        photo(original, title: "Original").frame(minWidth: 130)
                        photo(edited, title: "Example").frame(minWidth: 130)
                    }
                    VStack(spacing: 12) {
                        photo(original, title: "Original")
                        photo(edited, title: "Example")
                    }
                }
            } else if failed {
                Label("The example photo is unavailable. You can still follow the steps below.", systemImage: "photo")
            } else { ProgressView("Preparing example…").frame(maxWidth: .infinity, minHeight: 160) }
            if visual != .crop {
                Text(visual == .looks ? "\(look.name) · \(controlTitle)" : controlTitle).font(.headline)
                Slider(value: $amount, in: 0...1, step: 0.1)
                    .tint(Theme.accent).accessibilityLabel(controlTitle)
                    .accessibilityValue("\(Int(amount * 100)) percent")
                Button("Reset example") { amount = 0.6 }.frame(minHeight: 44)
            }
            Text(visual == .crop ? "Square framing shown using the real crop renderer." : "Illustration using Snapper’s editing pipeline. Your camera and saved photos are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .task(id: amount) { await renderExample() }
    }
    private func photo(_ image: UIImage, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 180)
                .background(.black.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Sample photo: \(title)")
            Text(title).font(.caption.weight(.semibold))
        }
    }
    private func renderExample() async {
        guard let url = Bundle.main.url(forResource: "demo-scene", withExtension: "jpg") else { failed = true; return }
        var recipe = PhotoRecipe(lookID: look.id)
        switch visual {
        case .looks: recipe.strength = amount
        case .brightness: recipe.adjustments.brightness = amount * 0.6
        case .warmth: recipe.adjustments.warmth = amount * 1.6 - 0.8
        case .crop: recipe.crop.shape = .square
        default: break
        }
        let before = await renderer.original(id: sampleID, sourceURL: url, maxPixelSize: 700)
        guard !Task.isCancelled else { return }
        let after = await renderer.preview(id: sampleID, sourceURL: url, look: look, recipe: recipe, maxPixelSize: 700)
        guard !Task.isCancelled else { return }
        original = before
        edited = after
        failed = before == nil || after == nil
    }
}
