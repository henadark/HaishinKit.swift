import libdatachannel

enum RTCGatheringState: Sendable {
    case new
    case inProgress
    case complete
}

extension RTCGatheringState {
    init?(cValue: rtcGatheringState) {
        switch cValue {
        case RTC_GATHERING_NEW:
            self = .new
        case RTC_GATHERING_INPROGRESS:
            self = .inProgress
        case RTC_GATHERING_COMPLETE:
            self = .complete
        default:
            return nil
        }
    }
}
