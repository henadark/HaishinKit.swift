import Foundation
import HaishinKit

actor HTTPSession: Session {
    var connected: Bool {
        get async {
            peerConnection.state == .connected
        }
    }

    @AsyncStreamed(.closed)
    private(set) var readyState: AsyncStream<SessionReadyState>

    var stream: any StreamConvertible {
        _stream
    }

    private let uri: URL
    private var location: URL?
    private var maxRetryCount: Int = 0
    private var _stream = MediaStream()
    private var method: SessionMethod
    private lazy var peerConnection: RTCPeerConnection = makePeerConnection()

    init(uri: URL, method: SessionMethod) {
        logger.level = .debug
        self.uri = uri
        self.method = method
    }

    func setMaxRetryCount(_ maxRetryCount: Int) {
        self.maxRetryCount = maxRetryCount
    }

    func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
        guard _readyState.value == .closed else {
            return
        }
        _readyState.value = .connecting
        peerConnection = makePeerConnection()
        switch method {
        case .ingest:
            try await _stream.setAudioSettings(.init(format: .opus))
            await _stream.tracks.forEach { track in
                peerConnection.addTrack(track)
            }
        case .playback:
            await _stream.setDirection(.recvonly)
            try peerConnection.addTrack(.audio, stream: _stream)
            try peerConnection.addTrack(.video, stream: _stream)
        }
        do {
            try peerConnection.setLocalDesciption(.offer)
            let answer = try await requestOffer(uri, offer: peerConnection.createOffer())
            try peerConnection.setRemoteDesciption(answer, type: .answer)
            _readyState.value = .open
        } catch {
            logger.warn(error)
            await _stream.close()
            peerConnection.close()
            _readyState.value = .closed
            throw error
        }
    }

    func close() async throws {
        guard let location, _readyState.value == .open else {
            return
        }
        _readyState.value = .closing
        var request = URLRequest(url: location)
        request.httpMethod = "DELETE"
        request.addValue("application/sdp", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
        await _stream.close()
        peerConnection.close()
        self.location = nil
        _readyState.value = .closed
    }

    private func requestOffer(_ url: URL, offer: String) async throws -> String {
        logger.debug(offer)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse {
            if let location = response.allHeaderFields["Location"] as? String {
                if location.hasSuffix("http") {
                    self.location = URL(string: location)
                } else {
                    var baseURL = "\(url.scheme ?? "http")://\(url.host ?? "")"
                    if let port = url.port {
                        baseURL += ":\(port)"
                    }
                    self.location = URL(string: "\(baseURL)\(location)")
                }
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makePeerConnection() -> RTCPeerConnection {
        let conneciton = RTCPeerConnection(RTCConfiguration(iceServers: []))
        conneciton.delegate = self
        return conneciton
    }
}

extension HTTPSession: RTCPeerConnectionDelegate {
    // MARK: RTCPeerConnectionDelegate
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didSet gatheringState: RTCGatheringState) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didSet state: RTCState) {
        Task {
            if state == .connected {
                if await method == .ingest {
                    await _stream.setDirection(.sendonly)
                }
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didReceive track: RTCTrack) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidated: RTCICECandidate) {
    }
}
