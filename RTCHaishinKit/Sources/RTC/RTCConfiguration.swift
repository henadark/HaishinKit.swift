import Foundation
import libdatachannel

struct RTCConfiguration: Sendable {
    let iceServers: [String]

    func createPeerConnection() -> Int32 {
        var config = rtcConfiguration()
        return rtcCreatePeerConnection(&config)
    }
}
