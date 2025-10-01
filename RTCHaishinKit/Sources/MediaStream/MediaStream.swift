import AVFoundation
import HaishinKit
import libdatachannel

actor MediaStream {
    enum Error: Swift.Error {
        case unsupportedCodec
    }

    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac, .opus]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    let id: String = UUID().uuidString
    private var _tracks: [MediaStreamTrack] = []
    var tracks: [MediaStreamTrack] {
        if _tracks.isEmpty {
            _tracks.append(.init(mid: "1", streamId: id, audioCodecSettings: outgoing.audioSettings))
            _tracks.append(.init(mid: "0", streamId: id, videoCodecSettings: outgoing.videoSettings))
        }
        return _tracks
    }
    private(set) var videoTrackId: UInt8? = UInt8.max
    private(set) var audioTrackId: UInt8? = UInt8.max
    package lazy var incoming = IncomingStream(self)
    package lazy var outgoing = OutgoingStream()
    package var outputs: [any StreamOutput] = []
    package var readyState: StreamReadyState = .idle
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private var direction: RTCDirection = .sendonly

    func setDirection(_ direction: RTCDirection) {
        self.direction = direction
        switch direction {
        case .recvonly:
            Task {
                await incoming.startRunning()
            }
        case .sendonly:
            outgoing.startRunning()
            Task {
                for await audio in outgoing.audioOutputStream {
                    append(audio.0, when: audio.1)
                }
            }
            Task {
                for await video in outgoing.videoOutputStream {
                    append(video)
                }
            }
            Task {
                for await video in outgoing.videoInputStream {
                    outgoing.append(video: video)
                }
            }
        default:
            break
        }
    }

    func close() async {
        _tracks.removeAll()
        switch direction {
        case .sendonly:
            outgoing.stopRunning()
        case .recvonly:
            Task {
                await incoming.stopRunning()
            }
        default:
            break
        }
    }
}

extension MediaStream: _Stream {
    func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.audioSettings = audioSettings
    }

    func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.videoSettings = videoSettings
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                Task {
                    for track in _tracks {
                        await track.append(sampleBuffer)
                    }
                }
            } else {
                outgoing.append(sampleBuffer)
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        case .audio:
            if sampleBuffer.formatDescription?.isCompressed == true {
                Task { await incoming.append(sampleBuffer) }
            } else {
                outgoing.append(sampleBuffer)
            }
        default:
            break
        }
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        switch audioBuffer {
        case let audioBuffer as AVAudioPCMBuffer:
            outgoing.append(audioBuffer, when: when)
            outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
        case let audioBuffer as AVAudioCompressedBuffer:
            Task {
                for track in _tracks {
                    await track.append(audioBuffer, when: when)
                }
            }
        default:
            break
        }
    }

    func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension MediaStream: RTCTrackDelegate {
    // MARK: RTCTrackDelegate
    nonisolated func track(_ track: RTCTrack, didSetOpen isOpen: Bool) {
    }

    nonisolated func track(_ track: RTCTrack, didOutput buffer: CMSampleBuffer) {
        Task {
            await incoming.append(buffer)
        }
    }

    nonisolated func track(_ track: RTCTrack, didOutput buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        Task {
            await incoming.append(buffer, when: when)
        }
    }
}

extension MediaStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}
