import Foundation
import libdatachannel

protocol RTCPeerConnectionDelegate: AnyObject {
    func peerConnection(_ peerConnection: RTCPeerConnection, didSet state: RTCState)
    func peerConnection(_ peerConnection: RTCPeerConnection, didSet gatheringState: RTCGatheringState)
    func peerConnection(_ peerConnection: RTCPeerConnection, didReceive track: RTCTrack)
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidated: RTCICECandidate)
}

final class RTCPeerConnection {
    static let audioMediaDescription = """
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:0
a=recvonly
a=rtpmap:111 opus/48000/2
a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1
"""

    static let videoMediaDescription = """
m=video 9 UDP/TLS/RTP/SAVPF 98
a=mid:1
a=recvonly
a=rtpmap:98 H264/90000
a=rtcp-fb:98 goog-remb
a=rtcp-fb:98 nack
a=rtcp-fb:98 nack pli
a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
"""

    static let bufferSize: Int = 1024 * 16

    weak var delegate: (any RTCPeerConnectionDelegate)?
    private let connection: Int32
    private(set) var state: RTCState = .new {
        didSet {
            delegate?.peerConnection(self, didSet: state)
        }
    }
    private(set) var tracks: [RTCTrack] = []
    private(set) var iceState: RTCICEState = .new
    private(set) var candidates: [RTCICECandidate] = []
    private(set) var signalingState: RTCSignalingState = .stable
    private(set) var gatheringState: RTCGatheringState = .new {
        didSet {
            delegate?.peerConnection(self, didSet: gatheringState)
        }
    }
    private(set) var localDescription: String = ""

    init(_ config: RTCConfiguration) {
        connection = config.createPeerConnection()
        rtcSetUserPointer(connection, Unmanaged.passUnretained(self).toOpaque())
        rtcSetLocalDescriptionCallback(connection) { _, sdp, _, pointer in
            guard let pointer else { return }
            if let sdp {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().localDescription = String(cString: sdp)
            }
        }
        rtcSetLocalCandidateCallback(connection) { _, candidate, mid, pointer in
            guard let pointer else { return }
            Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().didGenerateCandidate(.init(
                candidate: candidate,
                mid: mid
            ))
        }
        rtcSetStateChangeCallback(connection) { _, state, pointer in
            guard let pointer else { return }
            if let state = RTCState(cValue: state) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().state = state
            }
        }
        rtcSetGatheringStateChangeCallback(connection) { _, gatheringState, pointer in
            guard let pointer else { return }
            if let gatheringState = RTCGatheringState(cValue: gatheringState) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().gatheringState = gatheringState
            }
        }
        rtcSetSignalingStateChangeCallback(connection) { _, signalingState, pointer in
            guard let pointer else { return }
            if let signalingState = RTCSignalingState(cValue: signalingState) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().signalingState = signalingState
            }
        }
        rtcSetTrackCallback(connection) { _, track, pointer in
            guard let pointer else { return }
            Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().didReceiveTrack(.init(id: track))
        }
    }

    deinit {
        close()
        rtcDeletePeerConnection(connection)
    }

    func addTrack(_ track: MediaStreamTrack) {
        let connection = self.connection
        Task {
            try await track.addTrack(connection, direction: .sendonly)
        }
    }

    @discardableResult
    func addTrack(_ kind: MediaStreamKind, stream: MediaStream) throws -> RTCTrack {
        let sdp: String
        switch kind {
        case .audio:
            sdp = Self.audioMediaDescription
        case .video:
            sdp = Self.videoMediaDescription
        }
        let result = try RTCError.check(sdp.withCString { cString in
            rtcAddTrack(connection, cString)
        })
        let track = RTCTrack(id: result)
        track.delegate = stream
        tracks.append(track)
        return track
    }

    func setRemoteDesciption(_ sdp: String, type: SDPSessionDescriptionType) throws {
        logger.debug(sdp, type.rawValue)
        try RTCError.check([sdp, type.rawValue].withCStrings { cStrings in
            rtcSetRemoteDescription(connection, cStrings[0], cStrings[1])
        })
    }

    func setLocalDesciption(_ type: SDPSessionDescriptionType) throws {
        logger.debug(type.rawValue)
        try RTCError.check([type.rawValue].withCStrings { cStrings in
            rtcSetLocalDescription(connection, cStrings[0])
        })
    }

    func createOffer() throws -> String {
        return try CUtil.getString { buffer, size in
            rtcCreateOffer(connection, buffer, size)
        }
    }

    func createAnswer() throws -> String {
        return try CUtil.getString { buffer, size in
            rtcCreateAnswer(connection, buffer, size)
        }
    }

    func close() {
        do {
            try RTCError.check(rtcClosePeerConnection(connection))
        } catch {
            logger.warn(error)
        }
    }

    private func didGenerateCandidate(_ candidated: RTCICECandidate) {
        candidates.append(candidated)
        delegate?.peerConnection(self, didGenerate: candidated)
    }

    private func didReceiveTrack(_ track: RTCTrack) {
        delegate?.peerConnection(self, didReceive: track)
    }
}
