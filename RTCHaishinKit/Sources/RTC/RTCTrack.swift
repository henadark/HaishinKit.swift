import AVFAudio
import CoreMedia
import Foundation
import libdatachannel

protocol RTCTrackDelegate: AnyObject {
    func track(_ track: RTCTrack, didSetOpen open: Bool)
    func track(_ track: RTCTrack, didOutput buffer: CMSampleBuffer)
    func track(_ track: RTCTrack, didOutput buffer: AVAudioCompressedBuffer, when: AVAudioTime)
}

final class RTCTrack: RTCChannel {
    weak var delegate: (any RTCTrackDelegate)?

    override var isOpen: Bool {
        didSet {
            if isOpen {
                do {
                    packetizer = try makePacketizer()
                } catch {
                    logger.warn(error)
                }
            }
            delegate?.track(self, didSetOpen: isOpen)
        }
    }

    var mid: String {
        do {
            return try CUtil.getString { buffer, size in
                rtcGetTrackMid(id, buffer, size)
            }
        } catch {
            logger.warn(error)
            return ""
        }
    }

    var description: String {
        do {
            return try CUtil.getString { buffer, size in
                rtcGetTrackDescription(id, buffer, size)
            }
        } catch {
            logger.warn(error)
            return ""
        }
    }

    var ssrc: UInt32 {
        do {
            return try CUtil.getUInt32 { buffer, size in
                rtcGetSsrcsForTrack(id, buffer, size)
            }
        } catch {
            logger.warn(error)
            return 0
        }
    }

    private var packetizer: (any RTPPacketizer)?

    deinit {
        rtcDeleteTrack(id)
    }

    func append(_ buffer: CMSampleBuffer) {
        packetizer?.append(buffer) { packet in
            try? send(packet.data)
        }
    }

    func append(_ buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        packetizer?.append(buffer, when: when) { packet in
            try? send(packet.data)
        }
    }

    override func didReceiveMessage(_ message: Data) {
        do {
            let packet = try RTPPacket(message)
            packetizer?.append(packet)
        } catch {
            logger.warn(error)
        }
    }

    private func makePacketizer() throws -> (any RTPPacketizer)? {
        let description = try SDPMediaDescription(sdp: description)
        var result: (any RTPPacketizer)?
        let rtpmap = description.attributes.compactMap { attr -> (UInt8, String, Int, Int?)? in
            if case let .rtpmap(payload, codec, clock, channel) = attr { return (payload, codec, clock, channel) }
            return nil
        }
        guard !rtpmap.isEmpty else {
            return nil
        }
        switch rtpmap[0].1.lowercased() {
        case "opus":
            let packetizer = RTPOpusPacketizer<RTCTrack>(ssrc: ssrc, payloadType: description.payload)
            packetizer.delegate = self
            result = packetizer
        case "h264":
            let packetizer = RTPH264Packetizer<RTCTrack>(ssrc: ssrc, payloadType: description.payload)
            packetizer.delegate = self
            result = packetizer
        default:
            break
        }
        for attribute in description.attributes {
            switch attribute {
            case .fmtp(_, let params):
                result?.formatParameter = RTPFormatParameter(params)
            default:
                break
            }
        }
        return result
    }
}

extension RTCTrack: RTPPacketizerDelegate {
    // MARK: RTPPacketizerDelegate
    func packetizer(_ packetizer: some RTPPacketizer, didOutput buffer: CMSampleBuffer) {
        delegate?.track(self, didOutput: buffer)
    }

    func packetizer(_ packetizer: some RTPPacketizer, didOutput buffer: AVAudioCompressedBuffer, when: AVAudioTime) {
        delegate?.track(self, didOutput: buffer, when: when)
    }
}
