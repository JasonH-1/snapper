import SwiftUI

struct CuratedCollectionsView: View {
    let library: LookLibrary
    let renderer: PhotoRenderer
    let onApply: (CuratedStyle) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("Curated recipes built from Snapper looks and film tools. Preview free; Premium is required to export.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(CuratedCollection.releases) { collection in
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                // A readout like the camera's look dial.
                                Text(collection.edition)
                                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                                    .textCase(.uppercase)
                                    .foregroundStyle(.secondary)
                                Text(collection.title).font(Theme.lookName(.title2)).accessibilityAddTraits(.isHeader)
                                Text(collection.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            // The styles side by side, scrolling out to the screen edges.
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(collection.styles) { style in
                                        CuratedStyleCard(style: style, samplePhoto: collection.samplePhoto,
                                                         library: library, renderer: renderer) {
                                            onApply(style)
                                            dismiss()
                                        }
                                    }
                                }
                            }
                            .contentMargins(.horizontal, 20, for: .scrollContent)
                            .padding(.horizontal, -20)
                        }
                    }
                }.padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

private struct CuratedStyleCard: View {
    let style: CuratedStyle
    let samplePhoto: String
    let library: LookLibrary
    let renderer: PhotoRenderer
    let apply: () -> Void
    @State private var image: UIImage?
    @State private var sampleID = UUID()
    @State private var unavailable = false

    private var look: Look? { library.look(id: style.recipe.lookID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white.opacity(0.06)
                .frame(height: 250)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .accessibilityLabel("Sample photo with \(style.name)")
                    } else if unavailable {
                        Text("Sample preview unavailable").font(.caption).foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    // What the recipe is made of: its look and strength.
                    if let look {
                        Text("\(look.name) · \(Int((style.recipe.strength * 100).rounded()))%")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .textCase(.uppercase)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(10)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(style.name).font(Theme.lookName(.headline))
                Text(style.tip).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Button(action: apply) {
                    Text("Use")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .hairlineControl(cornerRadius: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 4)
                .disabled(look == nil)
                .accessibilityLabel("Use \(style.name)")
            }
            .padding(12)
        }
        .frame(width: 220)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task {
            guard let url = Bundle.main.url(forResource: samplePhoto, withExtension: "jpg")
                    ?? Bundle.main.url(forResource: "demo-scene", withExtension: "jpg"),
                  let look else { unavailable = true; return }
            image = await renderer.preview(id: sampleID, sourceURL: url, look: look, recipe: style.recipe, maxPixelSize: 700)
            unavailable = image == nil
        }
    }
}
