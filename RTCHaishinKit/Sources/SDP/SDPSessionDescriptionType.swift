import libdatachannel

enum SDPSessionDescriptionType: String, Sendable {
    case answer
    case offer
    case pranswer
    case rollback
}
