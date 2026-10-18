import SwiftUI

struct CuratedCollectionsView: View {
    let library: LookLibrary
    let renderer: PhotoRenderer
    let onApply: (CuratedStyle) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("Curated recipes built from Snapper looks and film tools. Preview free; Premium is required to export.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(CuratedCollection.releases) { collection in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(collection.edition.uppercased()).font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text(collection.title).font(Theme.lookName(.title)).accessibilityAddTraits(.isHeader)
                            Text(collection.subtitle).foregroundStyle(.secondary)
                            ForEach(collection.styles) { style in
                                CuratedStyleCard(style: style, library: library, renderer: renderer) {
                                    onApply(style)
                                    dismiss()
                                }
                            }
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
    let library: LookLibrary
    let renderer: PhotoRenderer
    let apply: () -> Void
    @State private var image: UIImage?
    @State private var sampleID = UUID()
    @State private var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(height: 150).clipped()
                    .accessibilityLabel("Sample photo with \(style.name)")
            } else if unavailable { Text("Sample preview unavailable").font(.caption).padding() }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 150) }
            VStack(alignment: .leading, spacing: 10) {
                Text(style.name).font(.headline)
                Text(style.tip).font(.subheadline).foregroundStyle(.secondary)
                Button("Use \(style.name)", action: apply)
                    .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                    .frame(minHeight: 44)
                    .disabled(library.look(id: style.recipe.lookID) == nil)
            }.padding(14)
        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
            .task {
                guard let url = Bundle.main.url(forResource: "demo-scene", withExtension: "jpg"),
                      let look = library.look(id: style.recipe.lookID) else { unavailable = true; return }
                image = await renderer.preview(id: sampleID, sourceURL: url, look: look, recipe: style.recipe, maxPixelSize: 700)
                unavailable = image == nil
            }
    }
}
