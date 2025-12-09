import Combine
import HaishinKit
import SwiftUI
import AVFoundation
import VideoToolbox

enum ViewType: String, CaseIterable, Identifiable {
    case metal
    case pip

    var id: Self { self }
}

@MainActor
final class PreferenceViewModel: ObservableObject {
    @Published var showPublishSheet: Bool = false

    var uri = Preference.default.uri
    var streamName = Preference.default.streamName

    private(set) var bitRateModes: [VideoCodecSettings.BitRateMode] = [.average]

    // MARK: - AudioCodecSettings.
    @Published var audioFormat: AudioCodecSettings.Format = .aac

    // MARK: - VideoCodecSettings.
    @Published var bitRateMode: VideoCodecSettings.BitRateMode = .average
    var isLowLatencyRateControlEnabled: Bool = false
    let sessionPreset: AVCaptureSession.Preset = .hd4K3840x2160

    // MARK: - Others
    @Published var viewType: ViewType = .metal
    var isGPURendererEnabled: Bool = true

    init() {
        if #available(iOS 16.0, tvOS 16.0, *) {
            bitRateModes.append(.constant)
        }
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            bitRateModes.append(.variable)
        }
    }

    func makeVideoCodecSettings(_ settings: VideoCodecSettings) -> VideoCodecSettings {
        var newSettings = settings
        newSettings.bitRateMode = bitRateMode
        newSettings.isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled
        newSettings.bitRate = StreamSettingsConstants.defaultVideoBitRate
        newSettings.profileLevel = kVTProfileLevel_H264_High_4_0 as String
        return newSettings
    }

    func makeAudioCodecSettings(_ settings: AudioCodecSettings) -> AudioCodecSettings {
        var newSettings = settings
        newSettings.format = audioFormat
        newSettings.bitRate = StreamSettingsConstants.defaultAudioBitRate // 64,000 bps
        return newSettings
    }

    func makeURL() -> URL? {
        if uri.contains("rtmp://") {
            return URL(string: uri + "/" + streamName)
        }
        return URL(string: uri)

//        return URL(string: "")
    }
}
