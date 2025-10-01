import libdatachannel

enum RTCState: Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

extension RTCState {
    init?(cValue: rtcState) {
        switch cValue {
        case RTC_NEW:
            self = .new
        case RTC_CONNECTING:
            self = .connecting
        case RTC_CONNECTED:
            self = .connected
        case RTC_DISCONNECTED:
            self = .disconnected
        case RTC_FAILED:
            self = .failed
        case RTC_CLOSED:
            self = .closed
        default:
            return nil
        }
    }
}
