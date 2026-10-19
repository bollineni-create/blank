import SwiftUI

#if os(iOS)
import UIKit

/// Hosts the SwiftUI share sheet on iPhone and iPad.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let host = UIHostingController(rootView: ShareView(
            extensionItems: items,
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: "Loom", code: NSUserCancelledError))
            }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

#else
import AppKit

/// Hosts the SwiftUI share sheet on Mac.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        view = NSHostingView(rootView: ShareView(
            extensionItems: items,
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: "Loom", code: NSUserCancelledError))
            }))
        preferredContentSize = NSSize(width: 420, height: 320)
    }
}
#endif
