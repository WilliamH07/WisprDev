import Foundation
import SafariServices

/// Native half of the Safari web extension. Safari requires it to exist, but
/// the agent does not use native messaging: the extension talks to Wisper over
/// its authenticated loopback server instead, which supports streaming.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
