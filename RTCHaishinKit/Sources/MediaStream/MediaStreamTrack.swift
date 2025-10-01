import AVFAudio
import CoreMedia
import Foundation
import HaishinKit
import libdatachannel

actor MediaStreamTrack {
    private static func generateSSRC() -> UInt32 {
        var ssrc: UInt32 = 0
        repeat {
            ssrc = UInt32.random(in: 1...UInt32.max)
        } while ssrc == 0
        return ssrc
    }

    private static func generateCName() -> String {
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    let codec: rtcCodec
    let ssrc: UInt32
    let pt: Int32
    let mid: String
    let name: String
    let msid: String
    let trackId: String
    let profile: String?
    let id: String = UUID().uuidString
    private var track: RTCTrack?

    init(mid: String, streamId: String, audioCodecSettings: AudioCodecSettings) {
        self.codec = audioCodecSettings.format.cValue ?? RTC_CODEC_OPUS
        self.ssrc = Self.generateSSRC()
        self.pt = 111
        self.mid = mid
        self.name = Self.generateCName()
        self.msid = streamId
        self.trackId = id
        self.profile = nil
    }

    init(mid: String, streamId: String, videoCodecSettings: VideoCodecSettings) {
        self.codec = videoCodecSettings.format.cValue
        self.ssrc = Self.generateSSRC()
        self.pt = 98
        self.mid = mid
        self.name = Self.generateCName()
        self.msid = streamId
        self.trackId = id
        self.profile = nil
    }

    func append(_ buffer: CMSampleBuffer) {
        track?.append(buffer)
    }

    func append(_ buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        track?.append(buffer, when: when)
    }

    func addTrack(_ connection: Int32, direction: RTCDirection) throws {
        var rtcTrackInit = makeRtcTrackInit(direction)
        let result = try RTCError.check(rtcAddTrackEx(connection, &rtcTrackInit))
        track = RTCTrack(id: result)
    }

    private func makeRtcTrackInit(_ direction: RTCDirection) -> rtcTrackInit {
        // TODO: Fix memory leak
        return rtcTrackInit(
            direction: direction.cValue,
            codec: codec,
            payloadType: pt,
            ssrc: ssrc,
            mid: strdup(mid),
            name: strdup(name),
            msid: strdup(msid),
            trackId: strdup(trackId),
            profile: profile == nil ? nil : strdup(profile)
        )
    }
}
