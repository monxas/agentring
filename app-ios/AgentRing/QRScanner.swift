import SwiftUI
import VisionKit

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let controller = UIViewController()
            let label = UILabel(); label.text = "Camera unavailable. Close this sheet and paste the QR payload."; label.numberOfLines = 0
            label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(label)
            NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor), label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24)])
            return controller
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { context.coordinator.found("") }
        return scanner
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var delivered = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if !delivered, let value = barcode.payloadStringValue {
                    delivered = true; dataScanner.stopScanning(); found(value); return
                }
            }
        }
    }
}
