import PhotosUI
import SwiftUI
import UIKit

struct UploadView: View {
    @StateObject private var viewModel = UploadViewModel()
    @State private var showingQueued = false
    @State private var showingPostPicker = false

    // The backend (lua/src/config.lua's max_tags_per_upload/max_tag_length,
    // defaults 12/32) silently truncates instead of rejecting an
    // over-the-limit submission — surface a heads-up client-side instead of
    // letting tags quietly disappear with no explanation.
    private var tagsWarning: String? {
        let parsed = viewModel.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed.count > 12 {
            return "Only the first 12 tags will be kept."
        }
        if parsed.contains(where: { $0.count > 32 }) {
            return "Tags longer than 32 characters will be truncated."
        }
        return nil
    }

    private var hasPickedFile: Bool {
        viewModel.pickedData != nil || viewModel.pickedFileURL != nil
    }

    // No longer gated on viewModel.isUploading -- that now tracks the most
    // recently enqueued upload's own background transfer, which can (and
    // should) keep running while the user picks and starts a completely
    // different upload. Nothing about the new BackgroundUploadManager
    // architecture requires serializing submissions on this screen.
    private var canSubmit: Bool {
        hasPickedFile && !viewModel.title.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MediaPickerHeroCard(
                    pickerItem: $viewModel.pickerItem,
                    pickedData: viewModel.pickedData,
                    pickedFileURL: viewModel.pickedFileURL,
                    isVideo: viewModel.isVideo,
                    isUploading: viewModel.isUploading
                )
                .onChange(of: viewModel.pickerItem) { _ in
                    Task { await viewModel.handlePickerSelection() }
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if hasPickedFile {
                    Button {
                        Task { await viewModel.analyze() }
                    } label: {
                        HStack {
                            if viewModel.isAnalyzing {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(viewModel.isAnalyzing ? "Analyzing…" : "Analyze")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isAnalyzing || viewModel.isUploading)

                    UploadCardSection("Details", "text.alignleft") {
                        TextField("Title", text: $viewModel.title)
                            .onChange(of: viewModel.title) { newValue in
                                if newValue.count > 160 { viewModel.title = String(newValue.prefix(160)) }
                            }
                        Divider()
                        TextField("Description", text: $viewModel.description, axis: .vertical)
                            .lineLimit(3...6)
                            .onChange(of: viewModel.description) { newValue in
                                if newValue.count > 2000 { viewModel.description = String(newValue.prefix(2000)) }
                            }
                    }

                    UploadCardSection("Category", "square.grid.2x2") {
                        UploadCategoryChipsRow(categories: viewModel.categories, selectedName: $viewModel.categoryName)
                        TextField("Category", text: $viewModel.categoryName)
                            .onChange(of: viewModel.categoryName) { newValue in
                                if newValue.count > 80 { viewModel.categoryName = String(newValue.prefix(80)) }
                            }
                    }

                    UploadCardSection("Tags", "tag") {
                        TagChipsField(tags: $viewModel.tags)
                        if let tagsWarning {
                            Text(tagsWarning).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            showingPostPicker = true
                        } label: {
                            Label("Reuse tags from one of your posts", systemImage: "tag.circle")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }

                    if viewModel.isVideo {
                        ThumbnailPickerCard(
                            thumbnail: $viewModel.customThumbnail,
                            videoURL: viewModel.pickedFileURL
                        )
                    }

                    UploadCardSection("Visibility", "eye") {
                        VisibilityCardPicker(visibility: $viewModel.visibility)
                    }

                    UploadCardSection("Settings", "slider.horizontal.3") {
                        Toggle("18+", isOn: $viewModel.isAdult)
                        Toggle("Comments enabled", isOn: $viewModel.commentsEnabled)
                        Toggle("Downloads enabled", isOn: $viewModel.downloadsEnabled)
                        Toggle("AI metadata", isOn: $viewModel.autoAI)
                    }

                    UploadCardSection("Schedule", "clock") {
                        Toggle("Schedule for later", isOn: $viewModel.scheduleEnabled)
                        if viewModel.scheduleEnabled {
                            DatePicker("Publish at", selection: $viewModel.publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }

                    if !viewModel.possibleDuplicates.isEmpty {
                        UploadCardSection("Similar to posts you already have", "sparkle.magnifyingglass") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(viewModel.possibleDuplicates) { match in
                                        duplicateThumbnail(match)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .animation(.easeOut(duration: 0.25), value: hasPickedFile)
        }
        .safeAreaInset(edge: .bottom) {
            publishBar
        }
        .navigationTitle("Upload")
        .nyxScreen()
        .sheet(isPresented: $showingPostPicker) {
            PostPickerSheet { tags, replace, _ in
                viewModel.tags = TagMerge.apply(tags, to: viewModel.tags, replace: replace).tags
                Haptics.light()
            }
        }
        .task { await viewModel.loadCategories() }
        // "Queued", not "complete" -- the transfer now runs in
        // BackgroundUploadManager independent of this screen (see
        // UploadViewModel.submit()'s doc comment), so this only confirms
        // the handoff happened. The real outcome (finished/failed) arrives
        // later as a separate notice -- see ImageGalleryApp.swift's alert
        // bound to BackgroundUploadManager.shared.completionNotice.
        .alert("Uploading in the background", isPresented: $showingQueued) {
            Button("OK") {}
        } message: {
            Text("You can leave this screen — we'll let you know when it's ready.")
        }
    }

    private var publishBar: some View {
        Button {
            Task {
                if await viewModel.submit() {
                    showingQueued = true
                    viewModel.reset()
                }
            }
        } label: {
            Group {
                if viewModel.isUploading && viewModel.uploadProgress > 0 {
                    ProgressView(value: viewModel.uploadProgress).tint(.white).frame(maxWidth: 120)
                } else if viewModel.isUploading {
                    ProgressView().tint(.white)
                } else {
                    Text("Publish").font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.3)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func duplicateThumbnail(_ match: DuplicateMatch) -> some View {
        VStack(spacing: 2) {
            if let urlString = match.thumbUrl, let url = URL(string: urlString) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(.secondary.opacity(0.15))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(match.title?.nilIfEmpty ?? "Untitled")
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 56)
        }
    }
}
