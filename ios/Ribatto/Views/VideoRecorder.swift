import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Records a match with the phone's camera. When recording stops the file is
/// handed straight to the import pipeline, so clips start appearing without
/// a trip through Photos.
struct VideoRecorder: UIViewControllerRepresentable {
    let onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The camera can record movies. Both halves matter: a device can have a
    /// camera that this picker still won't shoot video with, and asking for
    /// video capture in that state raises an exception rather than failing
    /// gracefully.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) && cameraMovieTypes != nil
    }

    /// The camera's movie media type, or nil if it can't shoot one.
    private static var cameraMovieTypes: [String]? {
        guard let available = UIImagePickerController.availableMediaTypes(for: .camera)
        else { return nil }
        let movie = available.filter { $0 == UTType.movie.identifier }
        return movie.isEmpty ? nil : movie
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator

        // Order is load-bearing. `cameraCaptureMode = .video` is only legal
        // once `mediaTypes` already contains the movie type — set the other way
        // round, UIKit raises NSInvalidArgumentException and takes the app down
        // the instant the camera button is tapped. The simulator has no camera,
        // so `isAvailable` is false there and this path never runs, which is
        // why it survived simulator testing and only showed up on a phone.
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              let movieTypes = Self.cameraMovieTypes else {
            // Caller checks `isAvailable` first; this is the belt to that
            // braces. A plain library picker is a harmless thing to show.
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [UTType.movie.identifier]
            return picker
        }

        picker.sourceType = .camera
        picker.mediaTypes = movieTypes
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        // the default cap is 10 minutes — a match runs far longer
        picker.videoMaximumDuration = 60 * 90
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let parent: VideoRecorder
        init(_ parent: VideoRecorder) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let url = info[.mediaURL] as? URL
            parent.dismiss()
            if let url { parent.onFinish(url) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
