import AVFoundation
import SwiftUI
import VisionKit
import Vision

// MARK: - Public UIViewControllerRepresentable

struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    var onCameraError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .black
        context.coordinator.startScanner(in: host, onError: onCameraError ?? { _ in })
        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// Called by SwiftUI when the view leaves the hierarchy — stop camera scanning.
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.stopScanner()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        private var fired = false
        private weak var hostViewController: UIViewController?
        private var scannerViewController: DataScannerViewController?
        private var onCameraError: ((String) -> Void)?

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func startScanner(in hostViewController: UIViewController, onError: @escaping (String) -> Void) {
            self.hostViewController = hostViewController
            self.onCameraError = onError

            guard DataScannerViewController.isSupported else {
                onError("当前设备不支持实时识别扫描")
                return
            }

            guard DataScannerViewController.isAvailable else {
                onError("扫描功能当前不可用，请稍后重试")
                return
            }

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                buildScanner(in: hostViewController, onError: onError)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted {
                        DispatchQueue.main.async {
                            guard let self, let host = self.hostViewController else { return }
                            self.buildScanner(in: host, onError: onError)
                        }
                    }
                    else { DispatchQueue.main.async { onError("请在「设置」中允许 PreConnect 访问摄像头") } }
                }
            default:
                DispatchQueue.main.async { onError("请在「设置 › PreConnect」中开启摄像头访问权限") }
            }
        }

        private func buildScanner(in hostViewController: UIViewController, onError: @escaping (String) -> Void) {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                recognizesMultipleItems: true,
                isHighFrameRateTrackingEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = self

            hostViewController.addChild(scanner)
            scanner.view.frame = hostViewController.view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostViewController.view.addSubview(scanner.view)
            scanner.didMove(toParent: hostViewController)

            do {
                try scanner.startScanning()
                scannerViewController = scanner
            } catch {
                onError("无法启动扫码：\(error.localizedDescription)")
                return
            }
        }

        func stopScanner() {
            scannerViewController?.stopScanning()
            scannerViewController?.willMove(toParent: nil)
            scannerViewController?.view.removeFromSuperview()
            scannerViewController?.removeFromParent()
            scannerViewController = nil
        }

        private func handleRecognizedItem(_ item: RecognizedItem) {
            guard !fired else { return }
            guard case .barcode(let code) = item,
                  let payload = code.payloadStringValue else { return }
            fired = true
            onFound(payload)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard let firstItem = addedItems.first else { return }
            DispatchQueue.main.async { [weak self] in
                self?.handleRecognizedItem(firstItem)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            DispatchQueue.main.async { [weak self] in
                self?.handleRecognizedItem(item)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            DispatchQueue.main.async {
                self.onCameraError?("扫描暂不可用：\(error.localizedDescription)")
            }
        }
    }
}
