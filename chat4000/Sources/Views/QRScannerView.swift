import SwiftUI
@preconcurrency import AVFoundation

#if os(iOS)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
import Vision
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformView = NSView
#endif

struct QRScannerView: View {
    var onScanned: (String) -> Void
    var onBack: () -> Void

    @State private var errorMessage: String?
    @State private var cameraPermission: CameraPermission = .unknown

    enum CameraPermission {
        case unknown
        case granted
        case denied
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            switch cameraPermission {
            case .unknown:
                ProgressView()
                    .tint(AppColors.textSecondary)

            case .denied:
                cameraPermissionDenied

            case .granted:
                cameraView
            }

            VStack {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(AppFonts.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(16)

                Spacer()

                VStack(spacing: 12) {
                    Text("Point at a chat4000 QR code")
                        .font(AppFonts.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.error)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(AppColors.errorBackground.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 60)
                .animation(.easeInOut(duration: 0.2), value: errorMessage)
            }
        }
        .task { await checkCameraPermission() }
    }

    private var cameraView: some View {
        QRCameraRepresentable { code in
            handleScannedCode(code)
        }
        .ignoresSafeArea()
    }

    private var cameraPermissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(AppColors.textSecondary)

            Text("Camera Access Required")
                .font(AppFonts.title)
                .foregroundStyle(AppColors.textPrimary)

            Text("Allow camera access in Settings to scan QR codes.")
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Open Settings", action: openSettings)
                .font(AppFonts.button)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
        }
        .padding(32)
    }

    private func checkCameraPermission() async {
        let initialStatus = AVCaptureDevice.authorizationStatus(for: .video)
        AppLog.log("📷 QR permission initial status=%ld", initialStatus.rawValue)
        switch initialStatus {
        case .authorized:
            cameraPermission = .granted
            AppLog.log("📷 QR permission already granted")
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraPermission = granted ? .granted : .denied
            AppLog.log("📷 QR permission requested → granted=%@", granted ? "true" : "false")
        default:
            cameraPermission = .denied
            AppLog.log("📷 QR permission denied (status=%ld)", initialStatus.rawValue)
        }
    }

    private func handleScannedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RelayCrypto.normalizePairingCode(trimmed)
        let pairingInvite = RelayCrypto.parsePairingURI(trimmed)
        let parsedConfig = GroupConfig.parse(trimmed)

        guard normalized.count == 8 || pairingInvite != nil || parsedConfig != nil else {
            errorMessage = "Not a valid chat4000 pairing code or group key"
            Task {
                try? await Task.sleep(for: .seconds(2))
                if errorMessage == "Not a valid chat4000 pairing code or group key" {
                    errorMessage = nil
                }
            }
            return
        }

        errorMessage = nil
        Haptics.success()
        onScanned(normalized.count == 8 ? normalized : trimmed)
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

struct QRCameraRepresentable: PlatformViewRepresentable {
    let onCodeScanned: (String) -> Void

    #if os(iOS)
    func makeUIView(context: Context) -> QRCameraPlatformView {
        let view = QRCameraPlatformView()
        view.onCodeScanned = onCodeScanned
        return view
    }

    func updateUIView(_ uiView: QRCameraPlatformView, context: Context) {}
    #elseif os(macOS)
    func makeNSView(context: Context) -> QRCameraPlatformView {
        let view = QRCameraPlatformView()
        view.onCodeScanned = onCodeScanned
        return view
    }

    func updateNSView(_ nsView: QRCameraPlatformView, context: Context) {}
    #endif
}

@MainActor
final class QRCameraPlatformView: PlatformView, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastScannedCode: String?
    private var didConfigureSession = false

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        configureCameraIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCameraIfNeeded()
    }

    private func configureCameraIfNeeded() {
        guard !didConfigureSession else {
            AppLog.log("📷 QR config: skipping (already configured)")
            return
        }

        // Defer setting didConfigureSession=true until configuration
        // actually succeeds. The previous order locked the view into a
        // "configured but no inputs" state if AVCaptureDevice.default(for:)
        // returned nil during the brief post-permission window after a
        // fresh install — making the first scan look broken.

        captureSession.beginConfiguration()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            AppLog.log("📷 QR config: camera device unavailable; will retry on layout")
            return
        }

        captureSession.addInput(input)
        AppLog.log("📷 QR config: input added (device=%@)", device.localizedName)

        #if os(iOS)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            AppLog.log("📷 QR config: cannot add metadata output")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        AppLog.log("📷 QR config: metadata output attached, types=%@", "\(output.metadataObjectTypes)")
        #elseif os(macOS)
        let output = AVCaptureVideoDataOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            return
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "chat4000Mac.QRFrames"))
        captureSession.addOutput(output)
        #endif

        captureSession.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        previewLayer = preview
        #if os(iOS)
        layer.addSublayer(preview)
        #elseif os(macOS)
        wantsLayer = true
        layer?.addSublayer(preview)
        #endif

        didConfigureSession = true
        AppLog.log("📷 QR config: success, starting session")

        Task.detached(priority: .userInitiated) { [captureSession] in
            // Run on a background thread per AVCaptureSession's threading
            // contract; startRunning blocks until the session is actually
            // up and emitting frames.
            if !captureSession.isRunning {
                captureSession.startRunning()
                AppLog.log("📷 QR session: startRunning returned (isRunning=%@)", captureSession.isRunning ? "true" : "false")
            }
        }
    }

    deinit {
        captureSession.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        AppLog.log("📷 QR metadata fired count=%ld", metadataObjects.count)
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue
        else {
            AppLog.log("📷 QR metadata: no readable code in frame")
            return
        }

        guard code != lastScannedCode else {
            AppLog.log("📷 QR metadata: duplicate code (debounce window), skipping")
            return
        }

        AppLog.log("📷 QR scanned code prefix=%@ len=%ld", String(code.prefix(40)), code.count)
        lastScannedCode = code
        onCodeScanned?(code)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lastScannedCode = nil
        }
    }
}

#if os(iOS)
extension QRCameraPlatformView {
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        ensureSessionRunning()
    }
}
#elseif os(macOS)
extension QRCameraPlatformView {
    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        ensureSessionRunning()
    }
}
#endif

extension QRCameraPlatformView {
    /// Belt-and-suspenders for two intermittent failures observed in the
    /// wild on the first scan after a fresh install:
    /// (1) `configureCameraIfNeeded` raced post-permission and bailed early
    ///     with no inputs attached — retry it here.
    /// (2) `startRunning` was deferred into a Task that hadn't completed by
    ///     the time the view was laid out — kick it again if needed.
    fileprivate func ensureSessionRunning() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        if !didConfigureSession {
            configureCameraIfNeeded()
        }

        if didConfigureSession, !captureSession.isRunning {
            let session = captureSession
            Task.detached(priority: .userInitiated) {
                if !session.isRunning {
                    session.startRunning()
                }
            }
        }
    }
}

#if os(macOS)
extension QRCameraPlatformView: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNBarcodeObservation,
                  let payload = observation.payloadStringValue
            else { return }

            Task { @MainActor [weak self] in
                guard let self, payload != self.lastScannedCode else { return }
                self.lastScannedCode = payload
                self.onCodeScanned?(payload)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.lastScannedCode = nil
                }
            }
        } catch {
            return
        }
    }
}
#endif
