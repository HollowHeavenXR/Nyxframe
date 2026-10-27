import PhotosUI
import SwiftUI

/// Full post editor, mirroring the web app's `MediaEditor` in
/// `frontend/src/components/media.jsx`.
///
/// Until now the iOS app could only change a post's visibility and pinned
/// state, and only from the Studio list -- title, description, tags and
/// category were frozen at upload time on both platforms even though
/// `PATCH /api/media/:id` has always supported editing them.
///
/// The endpoint REPLACES the post record rather than patching named fields,
/// so every control value the sheet doesn't edit is echoed back unchanged;
/// omitting `visibility` would reset the post to public and omitting
/// `isAdult` would silently un-mark an 18+ post. `publishAt` is deliberately
/// not sent: it is explicitly-only on the server, so leaving it out preserves
/// whatever schedule was set elsewhere.
struct MediaEditSheet: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var categoryId = 0
    @State private var subcategoryIds: [Int] = []
    @State private var newSubcategory = ""
    @State private var isAdult = false
    @State private var categories: [CategorySummary] = []
    @State private var isSaving = false
    @State private var showingPostPicker = false
    @State private var thumbnailItem: PhotosPickerItem?
    @State private var thumbnailBusy = false
    @State private var thumbnailError: String?

    private var selectedCategory: CategorySummary? {
        categories.first { $0.id == categoryId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Tags (comma separated)", text: $tags)
                        .textInputAutocapitalization(.never)
                    Button {
                        showingPostPicker = true
                    } label: {
                        Label("Reuse tags from one of your posts", systemImage: "tag.circle")
                    }
                }
                if let media = viewModel.media, media.isVideo {
                    thumbnailSection(media)
                }
                Section("Category") {
                    Picker("Category", selection: $categoryId) {
                        Text("Select a category").tag(0)
                        ForEach(categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    if let subs = selectedCategory?.subcategories, !subs.isEmpty {
                        ForEach(subs) { sub in
                            Button {
                                if let index = subcategoryIds.firstIndex(of: sub.id) {
                                    subcategoryIds.remove(at: index)
                                } else if subcategoryIds.count < 3 {
                                    subcategoryIds.append(sub.id)
                                }
                            } label: {
                                HStack {
                                    Text(sub.name)
                                    Spacer()
                                    if subcategoryIds.contains(sub.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Or add a new subcategory", text: $newSubcategory)
                }
                Section {
                    Toggle("Mark as 18+", isOn: $isAdult)
                } footer: {
                    Text("18+ posts stay hidden from anyone who has not verified their age.")
                }
            }
            .navigationTitle("Edit Post")
            .nyxScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty || categoryId == 0)
                }
            }
            .task { await prepare() }
            .sheet(isPresented: $showingPostPicker) {
                PostPickerSheet { picked, replace, _ in
                    tags = TagMerge.apply(picked, to: tags, replace: replace).tags
                }
            }
            .onChange(of: thumbnailItem) { item in
                guard let item else { return }
                Task { await uploadThumbnail(item) }
            }
        }
    }

    // Applies immediately (separate endpoint), unlike the rest of the form,
    // which waits for Save.
    @ViewBuilder
    private func thumbnailSection(_ media: MediaItem) -> some View {
        Section {
            HStack(spacing: 14) {
                CachedAsyncImage(url: media.thumbUrl.flatMap { URL(string: $0) }) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.hasCustomThumbnail == true ? "Custom" : "Automatic").font(.subheadline.weight(.semibold))
                    if thumbnailBusy {
                        ProgressView()
                    }
                }
            }
            PhotosPicker(selection: $thumbnailItem, matching: .images) {
                Label("Choose a new thumbnail", systemImage: "photo")
            }
            .disabled(thumbnailBusy)
            if media.hasCustomThumbnail == true {
                Button(role: .destructive) {
                    Task { await resetThumbnail(media) }
                } label: {
                    Label("Use automatic thumbnail", systemImage: "arrow.uturn.backward")
                }
                .disabled(thumbnailBusy)
            }
            if let thumbnailError {
                Text(thumbnailError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Thumbnail")
        } footer: {
            Text("Thumbnail changes apply right away.")
        }
    }

    private func uploadThumbnail(_ item: PhotosPickerItem) async {
        guard let mediaId = viewModel.media?.id else { return }
        thumbnailBusy = true
        thumbnailError = nil
        defer {
            thumbnailBusy = false
            thumbnailItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = ThumbnailImageTools.jpegData(from: data) else {
            thumbnailError = "Couldn't use that photo. Try another one."
            return
        }
        do {
            viewModel.media = try await GalleryAPIClient.shared.setMediaThumbnail(mediaId: mediaId, jpegData: jpeg)
            Haptics.light()
        } catch {
            thumbnailError = error.localizedDescription
        }
    }

    private func resetThumbnail(_ media: MediaItem) async {
        thumbnailBusy = true
        thumbnailError = nil
        defer { thumbnailBusy = false }
        do {
            viewModel.media = try await GalleryAPIClient.shared.clearMediaThumbnail(mediaId: media.id)
        } catch {
            thumbnailError = error.localizedDescription
        }
    }

    private func prepare() async {
        guard let media = viewModel.media else { return }
        title = media.title ?? ""
        description = media.description ?? ""
        tags = (media.tags ?? []).joined(separator: ", ")
        categoryId = media.categoryId ?? 0
        subcategoryIds = media.subcategoryIds ?? []
        isAdult = media.isAdult ?? false
        categories = (try? await GalleryAPIClient.shared.categories()) ?? []
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let newNames = newSubcategory.trimmingCharacters(in: .whitespaces)
        let ok = await viewModel.updatePost(
            title: title,
            description: description,
            tags: parsedTags,
            categoryId: categoryId,
            subcategoryIds: subcategoryIds,
            subcategoryNames: newNames.isEmpty ? [] : [newNames],
            isAdult: isAdult
        )
        if ok { dismiss() }
    }
}
