import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

/// A file attached to a note. The bytes live in the attachments directory on
/// disk; only this description is stored with the note.
struct NoteAttachment: Identifiable, Equatable {
    enum Kind: String, Codable {
        case document
        case image
        case video
        case audio

        /// Photos and videos, the kinds that appear in the carousel and mosaic.
        var isVisualMedia: Bool { self == .image || self == .video }
    }

    var id = UUID()
    var kind: Kind
    /// The name of the file inside the attachments directory.
    var fileName: String
    /// The name to show people, e.g. the document's original file name.
    var displayName: String
    /// Bytes on disk, for the size shown on document rows.
    var byteCount: Int = 0
    /// Voice memo length in seconds.
    var duration: TimeInterval = 0
    /// Normalized recording levels, used to draw a voice memo's waveform.
    var waveform: [Float] = []
    /// Filled in once a voice memo has been transcribed.
    var transcript: String?

    var url: URL? { AttachmentStore.url(forFileName: fileName) }

    var symbolName: String {
        switch kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .document:
            switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
            case "pdf": "doc.richtext"
            case "zip": "doc.zipper"
            case "md", "markdown": "doc.plaintext"
            default: "doc.text"
            }
        }
    }

    var formattedSize: String {
        ByteCountFormatStyle().format(Int64(byteCount))
    }

    /// e.g. "1:07".
    var formattedDuration: String {
        Duration.seconds(duration).formatted(
            .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

// Written by hand so attachments saved before voice memos existed still decode.
extension NoteAttachment: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, fileName, displayName, byteCount, duration, waveform, transcript
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decode(String.self, forKey: .displayName)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        waveform = try container.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
    }
}

// MARK: - Storage

/// Owns the on-disk attachment files.
enum AttachmentStore {
    /// The document types the paperclip button accepts.
    static let allowedDocumentTypes: [UTType] = [
        .plainText,
        UTType("net.daringfireball.markdown") ?? .plainText,
        .pdf,
        .zip
    ]

    static var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = support.appending(path: "Attachments", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func url(forFileName fileName: String) -> URL? {
        directory?.appending(path: fileName)
    }

    // MARK: Importing

    /// Copies a picked file into the attachments directory. Picked URLs are
    /// security scoped, so the copy happens inside an access block.
    static func importFile(at source: URL, kind: NoteAttachment.Kind) -> NoteAttachment? {
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else { return nil }
        return store(data, extension: source.pathExtension, displayName: source.lastPathComponent, kind: kind)
    }

    /// Writes data as a new attachment file.
    static func store(
        _ data: Data,
        extension fileExtension: String,
        displayName: String,
        kind: NoteAttachment.Kind
    ) -> NoteAttachment? {
        let fileName = "\(UUID().uuidString).\(fileExtension.isEmpty ? "dat" : fileExtension)"
        guard let destination = url(forFileName: fileName) else { return nil }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            print("Wispr: could not save attachment — \(error)")
            return nil
        }

        return NoteAttachment(
            kind: kind,
            fileName: fileName,
            displayName: displayName,
            byteCount: data.count
        )
    }

    static func kind(for contentType: UTType?) -> NoteAttachment.Kind {
        guard let contentType else { return .document }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) { return .video }
        if contentType.conforms(to: .image) { return .image }
        return .document
    }

    // MARK: Removing

    static func delete(_ attachments: [NoteAttachment]) {
        for attachment in attachments {
            guard let url = attachment.url else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Thumbnails

/// Downsampled previews for media attachments, kept in memory so scrolling a
/// day doesn't re-decode the same files.
@MainActor
@Observable
final class AttachmentThumbnails {
    static let shared = AttachmentThumbnails()

    private var cache: [UUID: Image] = [:]
    private var inFlight: Set<UUID> = []

    func cached(_ attachment: NoteAttachment) -> Image? {
        cache[attachment.id]
    }

    func load(_ attachment: NoteAttachment, maxPixelSize: CGFloat = 900) async -> Image? {
        if let cached = cache[attachment.id] { return cached }
        guard !inFlight.contains(attachment.id), let url = attachment.url else { return nil }

        inFlight.insert(attachment.id)
        defer { inFlight.remove(attachment.id) }

        let cgImage: CGImage?
        switch attachment.kind {
        case .image: cgImage = Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        case .video: cgImage = await Self.videoFrame(at: url)
        case .document, .audio: cgImage = nil
        }

        guard let cgImage else { return nil }
        let image = Image(decorative: cgImage, scale: 1, orientation: .up)
        cache[attachment.id] = image
        return image
    }

    func forget(_ attachments: [NoteAttachment]) {
        for attachment in attachments { cache[attachment.id] = nil }
    }

    // MARK: Decoding

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(at url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

// MARK: - Thumbnail view

/// Shows an attachment's preview image, loading it on first appearance.
struct AttachmentThumbnail: View {
    let attachment: NoteAttachment

    @State private var image: Image?
    private let thumbnails = AttachmentThumbnails.shared

    var body: some View {
        // The image lives in an overlay so its intrinsic size can never push the
        // surrounding layout around; the frame comes from the caller.
        Color.white.opacity(0.06)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: attachment.symbolName)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            .overlay {
                if attachment.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, Color.black.opacity(0.35))
                }
            }
            .clipped()
        .task(id: attachment.id) {
            if let cached = thumbnails.cached(attachment) {
                image = cached
            } else {
                image = await thumbnails.load(attachment)
            }
        }
    }
}
