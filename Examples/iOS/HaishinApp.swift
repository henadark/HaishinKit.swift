import HaishinKit
@preconcurrency import Logboard
import RTCHaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import SwiftUI

@main
struct HaishinApp: App {
    @State private var preference = PreferenceViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preference)
        }
    }

    init() {
        Task {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            await SessionBuilderFactory.shared.register(SRTSessionFactory())
            await SessionBuilderFactory.shared.register(HTTPSessionFactory())

            await RTCLogger.shared.setLevel(.debug)
            LBLogger(kRTCHaishinKitIdentifier).level = .debug
        }
    }
}
