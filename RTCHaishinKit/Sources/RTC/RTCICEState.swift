import libdatachannel

enum RTCICEState: Sendable {
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed
}

extension RTCICEState {
    init?(cValue: rtcIceState) {
        switch cValue {
        case RTC_ICE_NEW:
            self = .new
        case RTC_ICE_CHECKING:
            self = .checking
        case RTC_ICE_CONNECTED:
            self = .connected
        case RTC_ICE_COMPLETED:
            self = .completed
        case RTC_ICE_FAILED:
            self = .failed
        case RTC_ICE_DISCONNECTED:
            self = .disconnected
        case RTC_ICE_CLOSED:
            self = .closed
        default:
            return nil
        }
    }
}
