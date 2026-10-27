import AVFoundation
import UIKit

/// Helpers for custom video thumbnails (iOS only -- UIKit/AVFoundation).
enum ThumbnailImageTools {
    /// Largest side of a thumbnail we send; the server renders its own
    /// sizes from this, so anything bigger only costs upload time.
    static let maxEdge: CGFloat = 3840

    /// Whatever the photo library hands over (HEIC, PNG, huge panoramas)
    /// as a JPEG the server accepts.
    static func jpegData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(from: image)
    }

    static func jpegData(from image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        if scale >= 1 { return image.jpegData(compressionQuality: 0.88) }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.88)
    }

    /// One frame of a local video file, at `seconds`.
    static func frame(from videoURL: URL, at seconds: Double) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func duration(of videoURL: URL) async -> Double {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : 0
    }
}

/// Merges tags picked from another post into a comma-separated tag string
/// (case-insensitive, keeps order), or replaces it. Returns the new string
/// and how many tags were added.
enum TagMerge {
    static func apply(_ incoming: [String], to current: String, replace: Bool) -> (tags: String, added: Int) {
        let clean = { (list: [String]) in list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if replace {
            let tags = clean(incoming)
            return (tags.joined(separator: ", "), tags.count)
        }
        var tags = clean(current.split(separator: ",").map(String.init))
        var seen = Set(tags.map { $0.lowercased() })
        var added = 0
        for tag in clean(incoming) where !seen.contains(tag.lowercased()) {
            seen.insert(tag.lowercased())
            tags.append(tag)
            added += 1
        }
        return (tags.joined(separator: ", "), added)
    }
}
