import SwiftUI

#if canImport(UIKit)
@preconcurrency import AVFoundation
import QuotaCore
import UIKit

/// Camera QR reader for the Mac pairing invitation. The capture pipeline stops
/// after the first decoded payload so the sheet dismisses with exactly one
/// confirmation; camera permission and missing hardware surface through
/// `onUnavailable` instead of a silent black preview.
public struct PairingScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onUnavailable: (String) -> Void

    public init(onPayload: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {
        self.onPayload = onPayload; self.onUnavailable = onUnavailable
    }

    public func makeUIViewController(context: Context) -> PairingScannerController {
        PairingScannerController(onPayload: onPayload, onUnavailable: onUnavailable)
    }

    public func updateUIViewController(_ controller: PairingScannerController, context: Context) {}
}

// The conformance is main-actor isolated and the delegate queue below is `.main`,
// so metadata callbacks always arrive on the main actor.
public final class PairingScannerController: UIViewController, @MainActor AVCaptureMetadataOutputObjectsDelegate {
    private let onPayload: (String) -> Void
    private let onUnavailable: (String) -> Void
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var reported = false

    init(onPayload: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {
        self.onPayload = onPayload; self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.reported else { return }
                    granted ? self.startCapture() : self.onUnavailable(L("phone.scan.cameraDenied"))
                }
            }
        default:
            onUnavailable(L("phone.scan.cameraDenied"))
        }
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func startCapture() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            onUnavailable(L("phone.scan.cameraUnavailable")); return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration(); onUnavailable(L("phone.scan.cameraInitFailed")); return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    // The delegate queue is `.main`, so this callback already runs on the main actor.
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !reported else { return }
        guard let payload = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?.stringValue else { return }
        reported = true
        session?.stopRunning()
        onPayload(payload)
    }
}

#else

/// macOS placeholder: the QuotaPhone target also builds on macOS for tests.
public struct PairingScannerView: View {
    public init(onPayload: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {}
    public var body: some View { EmptyView() }
}

#endif
