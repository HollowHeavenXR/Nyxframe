import Combine
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Lets a picked video be received as a file on disk instead of `Data` —
/// `FileRepresentation` copies straight from the Photos library to a temp
/// file without ever materializing the whole video in memory, which is what
/// makes multi-GB video uploads possible at all on a memory-constrained
/// device. Images stay on the simpler `Data`-based path since they're
/// realistically never anywhere near this size.
struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var pickerItem: PhotosPickerItem?
    @Published var pickedData: Data?
    /// Set instead of `pickedData` for videos — see `PickedVideoFile`.
    @Published var pickedFileURL: URL?
    @Published var pickedFileName = "upload"
    @Published var pickedMimeType = "image/jpeg"
    @Published var isVideo = false

    @Published var title = ""
    @Published var description = ""
    @Published var categoryName = ""
    @Published var tags = ""
    @Published var isAdult = false
    @Published var visibility = "public"
    @Published var commentsEnabled = true
    @Published var downloadsEnabled = true
    @Published var autoAI = true
    @Published var scheduleEnabled = false
    @Published var publishAt = Date().addingTimeInterval(3600)

    @Published var categories: [CategorySummary] = []
    /// True only while `submit()` is validating/enqueueing -- the actual
    /// transfer runs in `BackgroundUploadManager` independent of this view
    /// model's lifetime, so this flips back to `false` as soon as the
    /// upload has been handed off, not when it finishes. See `submit()`'s
    /// doc comment for why that's the whole point of this rewrite.
    @Published var isUploading = false
    /// Live progress of the upload this view model most recently enqueued,
    /// for as long as this screen happens to stay open -- sourced from
    /// `BackgroundUploadManager.shared.progress`, which keeps updating
    /// whether or not anything is still observing it.
    @Published var uploadProgress: Double = 0
    @Published var errorMessage: String?
    @Published var possibleDuplicates: [DuplicateMatch] = []
    @Published var isAnalyzing = false
    /// Custom thumbnail for a video upload, as JPEG (nil = automatic).
    @Published var customThumbnail: Data?

    private let api = GalleryAPIClient.shared
    private var progressCancellable: AnyCancellable?

    /// No independent client-side cap -- this just mirrors whatever the
    /// backend is actually configured to accept (`ServerConfig`, fetched from
    /// `/api/health`), the same way the web app's upload page reads
    /// `MAX_UPLOAD_BYTES` from live config instead of hardcoding its own
    /// number. Videos stream from disk (see `PickedVideoFile` and
    /// `GalleryAPIClient.upload`'s `.fileURL` case) rather than being held in
    /// memory, so raising this doesn't cost RAM.
    private var maxClientUploadBytes: Int { ServerConfig.shared.maxUploadBytes }

    /// This deployment's Cloudflare tunnel hard-413s any single request body
    /// over ~100MB regardless of the server's own configured upload limit
    /// (confirmed live). Comfortably under that -- used here only to decide
    /// whether `analyze()`'s standalone preview call (below, always a
    /// single one-shot request, no chunked variant) is even worth
    /// attempting for a given file. `submit()` no longer needs this
    /// threshold itself: `BackgroundUploadManager` (see its own
    /// `chunkedThresholdBytes`) now decides direct-vs-chunked for the real
    /// upload.
    private static let chunkedUploadThresholdBytes = 60 * 1024 * 1024

    func loadCategories() async {
        categories = (try? await api.categories()) ?? []
    }

    func handlePickerSelection() async {
        guard let pickerItem else { return }
        errorMessage = nil
        clearPickedFile()
        isVideo = pickerItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            if isVideo {
                guard let file = try await pickerItem.loadTransferable(type: PickedVideoFile.self) else {
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? nil
                guard let fileSize = size else {
                    try? FileManager.default.removeItem(at: file.url)
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                if fileSize > maxClientUploadBytes {
                    try? FileManager.default.removeItem(at: file.url)
                    let limitMB = maxClientUploadBytes / (1024 * 1024)
                    errorMessage = "That file is too large to upload from the app (over \(limitMB)MB). Try a shorter clip or a smaller export, or upload it from the web app instead."
                    return
                }
                pickedFileURL = file.url
                pickedMimeType = "video/mp4"
                pickedFileName = "upload.mp4"
            } else {
                let data = try await pickerItem.loadTransferable(type: Data.self)
                guard let data else {
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                if data.count > maxClientUploadBytes {
                    let limitMB = maxClientUploadBytes / (1024 * 1024)
                    errorMessage = "That file is too large to upload from the app (over \(limitMB)MB). Try a shorter clip or a smaller export, or upload it from the web app instead."
                    return
                }
                pickedData = data
                pickedMimeType = "image/jpeg"
                pickedFileName = "upload.jpg"
            }
        } catch {
            errorMessage = "Could not read that file: \(error.localizedDescription)"
        }
    }

    /// Pre-submit AI autofill -- see `GalleryAPIClient.analyzeMedia`'s doc
    /// comment. Only fills fields the user hasn't already typed something
    /// into, same "current || suggestion" intent as web's analyze().
    func analyze() async {
        guard pickedData != nil || pickedFileURL != nil else {
            errorMessage = "Choose a photo or video first."
            return
        }
        // Unlike submit() above, GalleryAPIClient.analyzeMedia always sends
        // one plain multipart request -- /api/media/analyze (routes.lua) is
        // a standalone "preview before uploading" endpoint with no chunked-
        // session counterpart to route through instead. Decline up front
        // rather than let a large file 413 with a raw Cloudflare error page:
        // this is a pure convenience preview, and auto_ai already runs the
        // same analysis server-side during the real (chunked-capable)
        // upload regardless, so nothing is lost by skipping it here.
        var pickedSize: Int?
        if let pickedData {
            pickedSize = pickedData.count
        } else if let pickedFileURL {
            pickedSize = (try? FileManager.default.attributesOfItem(atPath: pickedFileURL.path)[.size] as? Int) ?? nil
        }
        if let pickedSize, pickedSize > Self.chunkedUploadThresholdBytes {
            errorMessage = "This file is too large to analyze here — go ahead and upload it directly; AI metadata still runs automatically."
            return
        }
        isAnalyzing = true
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            let response: MediaAnalyzeResponse
            if let pickedFileURL {
                response = try await api.analyzeMedia(fileURL: pickedFileURL, fileName: pickedFileName, mimeType: pickedMimeType, titleHint: title, descriptionHint: description, tagsHint: tags)
            } else if let pickedData {
                response = try await api.analyzeMedia(data: pickedData, fileName: pickedFileName, mimeType: pickedMimeType, titleHint: title, descriptionHint: description, tagsHint: tags)
            } else {
                return
            }
            possibleDuplicates = response.possibleDuplicates ?? []
            guard let analysis = response.analysis else { return }
            if title.isEmpty { title = analysis.title ?? "" }
            if description.isEmpty { description = analysis.description ?? "" }
            if categoryName.isEmpty { categoryName = analysis.categoryName ?? "" }
            if tags.isEmpty, let suggestedTags = analysis.tags, !suggestedTags.isEmpty {
                tags = suggestedTags.joined(separator: ", ")
            }
            if analysis.isAdult == true { isAdult = true }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Validates the form, hands the picked file off to
    /// `BackgroundUploadManager` for the actual transfer, and returns once
    /// that hand-off's own setup is done -- NOT once the upload finishes
    /// (see `BackgroundUploadManager.enqueue`'s doc comment: the whole
    /// point is that the transfer survives the app being backgrounded or
    /// killed, which rules out resuming an in-memory awaited continuation
    /// for the "it finished" signal; `enqueue` itself is `async` only to
    /// guarantee its own bounded setup -- copy the file, register the
    /// first background task -- actually completes before this returns).
    /// `true` means "successfully queued for background transfer", not
    /// "upload complete" -- the real outcome surfaces later via
    /// `BackgroundUploadManager.shared.completionNotice` (see
    /// `ImageGalleryApp.swift`'s alert), same as web's `UploadPage.jsx`
    /// showing "queued" and moving on rather than blocking on the
    /// transfer. The caller (`UploadView`) is free to dismiss/navigate the
    /// instant this returns `true`.
    func submit() async -> Bool {
        guard pickedData != nil || pickedFileURL != nil else {
            errorMessage = "Choose a photo or video first."
            return false
        }
        errorMessage = nil

        var publishAtString: String?
        if scheduleEnabled {
            let formatter = ISO8601DateFormatter()
            publishAtString = formatter.string(from: publishAt)
        }

        var fields = GalleryAPIClient.UploadFields(
            title: title,
            description: description,
            categoryId: nil,
            categoryName: categoryName,
            tags: tags,
            isAdult: isAdult,
            visibility: visibility,
            commentsEnabled: commentsEnabled,
            downloadsEnabled: downloadsEnabled,
            autoAI: autoAI,
            publishAt: publishAtString
        )

        let sourceURL: URL
        if let pickedFileURL {
            sourceURL = pickedFileURL
        } else if let pickedData {
            // BackgroundUploadManager always transfers from a file on disk
            // -- background URLSession upload tasks require a file-backed
            // body regardless of size. A picked image previously only got
            // written to disk above the old chunked threshold; now it
            // always does, matching how a picked video already worked.
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)-\(pickedFileName)")
            do {
                try pickedData.write(to: tempURL)
            } catch {
                errorMessage = "Could not prepare the upload: \(error.localizedDescription)"
                return false
            }
            sourceURL = tempURL
        } else {
            return false
        }

        // A custom thumbnail goes up first (small, foreground); its token
        // rides along with the upload and the server attaches it once the
        // post exists -- even if this upload finishes in the background.
        if isVideo, let customThumbnail {
            do {
                fields.thumbnailToken = try await api.stageUploadThumbnail(jpegData: customThumbnail)
            } catch {
                errorMessage = "Couldn't upload the thumbnail: \(error.localizedDescription)"
                return false
            }
        }

        isUploading = true
        uploadProgress = 0
        let id = await BackgroundUploadManager.shared.enqueue(sourceURL: sourceURL, filename: pickedFileName, mimeType: pickedMimeType, fields: fields)
        observeProgress(id: id)
        // myMedia() is cached (see GalleryAPIClient+Endpoints.swift) -- this
        // upload won't be visible server-side for a while yet (still
        // transferring, and possibly still a background finish job after
        // that), but invalidating now means the list is already fresh by
        // the time it does land instead of sitting stale for the rest of
        // the cache's TTL.
        Task { await APIResponseCache.shared.invalidate(pathPrefix: "/api/me/media") }
        Haptics.light()
        return true
    }

    /// Mirrors this upload's live progress (and, once it's gone from the
    /// dict, its completion) for as long as this view model stays alive --
    /// `BackgroundUploadManager` itself doesn't need or wait for an
    /// observer; this purely feeds the on-screen progress bar while the
    /// user happens to still be looking at it.
    private func observeProgress(id: String) {
        progressCancellable = BackgroundUploadManager.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progressById in
                guard let self else { return }
                if let value = progressById[id] {
                    self.uploadProgress = value
                    self.isUploading = true
                } else {
                    self.isUploading = false
                    self.progressCancellable = nil
                }
            }
    }

    /// Removes any picked-video temp file so a "change file" tap or a reset
    /// doesn't leak temp files across selections.
    private func clearPickedFile() {
        customThumbnail = nil
        pickedData = nil
        if let pickedFileURL {
            try? FileManager.default.removeItem(at: pickedFileURL)
        }
        pickedFileURL = nil
    }

    func reset() {
        pickerItem = nil
        clearPickedFile()
        title = ""
        description = ""
        categoryName = ""
        tags = ""
        isAdult = false
        scheduleEnabled = false
        possibleDuplicates = []
    }
}
