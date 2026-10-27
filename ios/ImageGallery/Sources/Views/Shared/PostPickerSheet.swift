import SwiftUI

/// "Reuse tags from a post": the signed-in user's own tagged posts,
/// searchable by title or tag (or a pasted post link), in pages of 36.
/// Tapping a post hands its tags back and closes the sheet. Mirrors the web
/// app's PostPicker (frontend/src/components/PostPicker.jsx).
struct PostPickerSheet: View {
    /// (tags, replace) -- replace == false means "add to my tags".
    let onPick: ([String], Bool, PostPickerItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var items: [PostPickerItem] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var replace = false
    @State private var generation = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Apply", selection: $replace) {
                        Text("Add to my tags").tag(false)
                        Text("Replace my tags").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    } else if !isLoading && items.isEmpty {
                        Text(query.isEmpty ? "None of your posts have tags yet." : "No posts with tags match that search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onPick(item.tags ?? [], replace, item)
                                dismiss()
                            } label: {
                                card(item)
                            }
                            .buttonStyle(NyxPressStyle(scale: 0.97))
                            .onAppear {
                                if item.id == items.last?.id, hasMore, !isLoading {
                                    Task { await load(reset: false) }
                                }
                            }
                        }
                    }

                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Copy tags from a post")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, tag, or post link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .nyxScreen()
            .task(id: query) {
                // Settle typing for 250ms before searching.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                if Task.isCancelled { return }
                await load(reset: true)
            }
        }
    }

    private func card(_ item: PostPickerItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: item.thumbUrl.flatMap { URL(string: $0) }) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if item.mediaKind == "video" {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .padding(5)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(item.title?.nilIfEmpty ?? "Post #\(item.id)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text((item.tags ?? []).prefix(4).map { "#\($0)" }.joined(separator: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(item.tags?.count ?? 0) tag\(item.tags?.count == 1 ? "" : "s")")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Nyx.mist)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nyxGlass(radius: 14)
    }

    private func load(reset: Bool) async {
        generation += reset ? 1 : 0
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if myGeneration == generation { isLoading = false } }
        do {
            let response = try await GalleryAPIClient.shared.postPicker(query: query, offset: reset ? 0 : items.count)
            guard myGeneration == generation else { return }
            items = reset ? response.items : items + response.items
            hasMore = response.hasMore ?? false
        } catch {
            if !error.isCancellation, myGeneration == generation { errorMessage = error.localizedDescription }
        }
    }
}
