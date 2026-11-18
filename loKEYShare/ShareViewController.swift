import UIKit
import SwiftUI

/// Расширение «Поделиться в loKEY»: шифрует вложения ключом «Входящих» и кладёт во «Входящие» App Group.
/// Ключи кейсов здесь недоступны — перенос в кейс делается позже в приложении.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 14 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1)
        overrideUserInterfaceStyle = .dark

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers,
                               finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
                               cancel: { [weak self] in
                                   self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                               })
        self.model = model

        let host = UIHostingController(rootView: ShareRootView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        model.load()
    }
}
