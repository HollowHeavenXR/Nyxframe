import PhotosUI
import SwiftUI
import UIKit

/// Upload form: an optional custom thumbnail for the video being uploaded
/// -- a photo from the library, or a frame picked from the video itself.
/// `thumbnail` is JPEG data (nil = automatic: the server grabs a frame).
struct ThumbnailPickerCard: View {
    @Binding var thumbnail: Data?
    let videoURL: URL?
    var disabled = false

    @State private var photoItem: PhotosPickerItem?
    @State private var showingFramePicker = false
    @State private var errorMessage: String?

    var body: some View {
        UploadCardSection("Thumbnail", "photo.on.rectangle") {
            HStack(alignment: .center, spacing: 14) {
                preview
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(thumbnail == nil ? "Automatic" : "Custom thumbnail")
                        .font(.subheadline.weight(.semibold))
                    Text(thumbnail == nil ? "A frame from the video, picked for you." : "Shown on the video's card and player.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            .disabled(disabled)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let data, let jpeg = ThumbnailImageTools.jpegData(from: data) {
                    thumbnail = jpeg
                    errorMessage = nil
                } else {
                    errorMessage = "Couldn't use that photo. Try another one."
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showingFramePicker) {
            if let videoURL {
                VideoFramePickerSheet(videoURL: videoURL) { jpeg in
                    thumbnail = jpeg
                    errorMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label("Photos", systemImage: "photo")
        }
        .buttonStyle(.bordered)
        if videoURL != nil {
            Button {
                showingFramePicker = true
            } label: {
                Label("Pick a frame", systemImage: "film")
            }
            .buttonStyle(.bordered)
        }
        if thumbnail != nil {
            Button(role: .destructive) {
                thumbnail = nil
            } label: {
                Label("Automatic", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail, let image = UIImage(data: thumbnail) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
    }
}

/// Scrub through a local video and use the frame you stop on.
struct VideoFramePickerSheet: View {
    let videoURL: URL
    let onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var frame: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.85))
                    if let frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if duration > 0 {
                    Slider(value: $time, in: 0...duration)
                    Text(Self.timestamp(time) + " / " + Self.timestamp(duration))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Pick a frame")
            .navigationBarTitleDisplayMode(.inline)
            .nyxScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use frame") {
                        if let frame, let jpeg = ThumbnailImageTools.jpegData(from: frame) {
                            onPick(jpeg)
                        }
                        dismiss()
                    }
                    .disabled(frame == nil)
                }
            }
            .task {
                duration = await ThumbnailImageTools.duration(of: videoURL)
                time = min(1, duration)
            }
            .task(id: time) {
                // Settle the slider briefly so dragging doesn't decode
                // dozens of frames.
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
                if let image = await ThumbnailImageTools.frame(from: videoURL, at: time) {
                    frame = image
                }
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
