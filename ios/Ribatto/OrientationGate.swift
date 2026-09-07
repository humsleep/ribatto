import SwiftUI
import UIKit

/// Portrait everywhere except a video player.
///
/// Every screen in this app is laid out for portrait — the library, the
/// settings card, the reel editor. Landscape was declared in the Info.plist but
/// never designed: the tab bar floated over the content and, worst of all, the
/// clip player shrank the video to a stamp in the middle of a row of controls,
/// which is the opposite of why anyone rotates.
///
/// So the app is pinned to portrait and the players opt back in. Watching a
/// 16:9 rally sideways and full-screen is the one place landscape earns itself.
enum OrientationGate {
    /// Read by the app delegate on every rotation query.
    static var allowsLandscape = false {
        didSet {
            guard allowsLandscape != oldValue else { return }
            // Ask UIKit to re-evaluate now; without this the change only takes
            // effect the next time something else triggers an update.
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene else { return }
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: allowsLandscape ? .allButUpsideDown : .portrait))
            // The controller that decides is the one on top. A player lives in
            // a sheet, so telling only the root controller to re-ask left the
            // sheet pinned to whatever the app allowed when it opened.
            var top = scene.keyWindow?.rootViewController
                ?? scene.windows.first?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        OrientationGate.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

extension View {
    /// Lets this screen rotate, and pins the app back to portrait when it goes
    /// away. Paired with `onDisappear` so a dismissed player cannot leave the
    /// rest of the app sideways.
    func allowsLandscape(_ enabled: Bool = true) -> some View {
        onAppear { if enabled { OrientationGate.allowsLandscape = true } }
            .onDisappear { OrientationGate.allowsLandscape = false }
    }
}
