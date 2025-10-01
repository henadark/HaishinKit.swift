import libdatachannel

enum RTCSignalingState: Sendable {
    case stable
    case haveLocalOffer
    case haveRemoteOffer
    case haveLocalPRAnswer
    case haveRemotePRAnswer
}

extension RTCSignalingState {
    init?(cValue: rtcSignalingState) {
        switch cValue {
        case RTC_SIGNALING_STABLE:
            self = .stable
        case RTC_SIGNALING_HAVE_LOCAL_OFFER:
            self = .haveLocalOffer
        case RTC_SIGNALING_HAVE_REMOTE_OFFER:
            self = .haveRemoteOffer
        case RTC_SIGNALING_HAVE_LOCAL_PRANSWER:
            self = .haveLocalPRAnswer
        case RTC_SIGNALING_HAVE_REMOTE_PRANSWER:
            self = .haveRemotePRAnswer
        default:
            return nil
        }
    }
}
