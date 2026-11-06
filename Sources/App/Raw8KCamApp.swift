import SwiftUI
import UIKit

@main
struct Raw8KCamApp: App {
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
