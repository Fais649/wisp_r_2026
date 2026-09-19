import SwiftUI
import UIKit
import QuickLook
import VisionKit
import UniformTypeIdentifiers

// MARK: - Quick Look preview

/// Previews any attachment: text, markdown, PDF and zip listings as well as
/// images and video playback.
struct AttachmentPreview: UIViewControllerRepresentable {
    let entries: [AttachmentPreviewRequest.Entry]
    var startIndex: Int = 0

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = min(startIndex, max(entries.count - 1, 0))
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [dismiss] _ in dismiss() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.entries = entries
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var entries: [AttachmentPreviewRequest.Entry]

        init(entries: [AttachmentPreviewRequest.Entry]) {
            self.entries = entries
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            entries.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            PreviewItem(url: entries[index].url, title: entries[index].title)
        }
    }

    /// Carries a readable title, since the files on disk are named by UUID.
    private final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}

/// What the day view and editor present when an attachment is tapped.
struct AttachmentPreviewRequest: Identifiable {
    struct Entry {
        let url: URL
        let title: String
    }

    let id = UUID()
    let entries: [Entry]
    let startIndex: Int

    /// Builds a request from attachments, starting on the one that was tapped.
    init?(_ attachments: [NoteAttachment], startingAt attachment: NoteAttachment) {
        let entries = attachments.compactMap { candidate -> Entry? in
            guard let url = candidate.url else { return nil }
            return Entry(url: url, title: candidate.displayName)
        }
        guard !entries.isEmpty else { return nil }

        self.entries = entries
        startIndex = attachments.firstIndex { $0.id == attachment.id } ?? 0
    }
}

// MARK: - Camera

/// The system camera, used for taking a photo or recording a video straight
/// into a note.
struct CameraPicker: UIViewControllerRepresentable {
    /// False in the simulator and on devices without a camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (NoteAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (NoteAttachment) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (NoteAttachment) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let movieURL = info[.mediaURL] as? URL {
                if let attachment = AttachmentStore.importFile(at: movieURL, kind: .video) {
                    onCapture(attachment)
                }
            } else if let image = info[.originalImage] as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) {
                if let attachment = AttachmentStore.store(
                    data,
                    extension: "jpg",
                    displayName: "Photo",
                    kind: .image
                ) {
                    onCapture(attachment)
                }
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

// MARK: - Document scanner

/// VisionKit's document camera. Scanned pages are combined into a single PDF,
/// the way Notes stores a scan.
struct DocumentScanner: UIViewControllerRepresentable {
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    let onScan: (NoteAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onScan: (NoteAttachment) -> Void
        private let onFinish: () -> Void

        init(onScan: @escaping (NoteAttachment) -> Void, onFinish: @escaping () -> Void) {
            self.onScan = onScan
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            if let data = Self.makePDF(from: pages),
               let attachment = AttachmentStore.store(
                   data,
                   extension: "pdf",
                   displayName: scan.title.isEmpty ? "Scan.pdf" : "\(scan.title).pdf",
                   kind: .document
               ) {
                onScan(attachment)
            }
            onFinish()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            print("Wispr: document scan failed — \(error)")
            onFinish()
        }

        /// One page per scanned image, each sized to its own image.
        private static func makePDF(from pages: [UIImage]) -> Data? {
            guard !pages.isEmpty else { return nil }

            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pages[0].size))
            return renderer.pdfData { context in
                for page in pages {
                    let bounds = CGRect(origin: .zero, size: page.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    page.draw(in: bounds)
                }
            }
        }
    }
}
