import AVFoundation
import HaishinKit
import MediaPlayer
import Photos
import RTCHaishinKit
import SwiftUI

@MainActor
final class PublishViewModel: ObservableObject {
    private enum Keys {
        static let currentFPS = "publish_fps"
        static let videoBitRates = "publish_bitrate"
    }

    @Published var currentFPS: FPS = .fps30 {
        didSet {
            UserDefaults.standard.set(currentFPS.rawValue, forKey: Keys.currentFPS)
        }
    }
    @Published var visualEffectItem: VideoEffectItem = .none
    @Published private(set) var error: Error? {
        didSet {
            if error != nil {
                isShowError = true
            }
        }
    }
    @Published var isShowError = false
    @Published var showPreLiveDialog = false
    @Published private(set) var isAudioMuted = false
    @Published private(set) var isTorchEnabled = false
    @Published private(set) var readyState: SessionReadyState = .closed
    @Published var audioSource: AudioSource = .empty {
        didSet {
            guard audioSource != oldValue else {
                return
            }
            selectAudioSource(audioSource)
        }
    }
    @Published private(set) var audioSources: [AudioSource] = []
    @Published private(set) var isRecording = false
    @Published private(set) var stats: [Stats] = []
    @Published private(set) var currentCamera: String = "Back"
    @Published private(set) var isDualCameraEnabled: Bool = false
    @Published private(set) var isVolumeOn: Bool = false
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var videoDimensions: String = ""
    @Published private(set) var batteryUsed: Float = 0
    @Published private(set) var streamDuration: TimeInterval = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var currentUploadKBps: Int = 0
    private var streamStartBattery: Float = 0
    private var streamStartTime: Date?
    private var batteryTimer: Timer?
    private var durationTimer: Timer?
    @Published var videoBitRates: Double = 2000 {
        didSet {
            UserDefaults.standard.set(videoBitRates, forKey: Keys.videoBitRates)
            Task {
                guard let session else {
                    return
                }
                var videoSettings = await session.stream.videoSettings
                videoSettings.bitRate = Int(videoBitRates * 1000)
                try await session.stream.setVideoSettings(videoSettings)
            }
        }
    }
    // If you want to use the multi-camera feature, please make create a MediaMixer with a capture mode.
    // let mixer = MediaMixer(captureSesionMode: .multi)
    private(set) var mixer = MediaMixer(captureSessionMode: .single)
    private var tasks: [Task<Void, Swift.Error>] = []
    private var session: (any Session)?
    private var recorder: StreamRecorder?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var audioSourceService = AudioSourceService()
    @ScreenActor private var currentVideoEffect: VideoEffect?
    @ScreenActor private var bitStripEffect: BitStripEffect?
    private let barHeightPx: CGFloat = StreamSettingsConstants.bandHeightPx

    private var retryCount = 0
    private let maxRetryCount = 5
    private var isStopping = false
    private var reconnectTask: Task<Void, Never>?

//    private let fullResOutput = AVCaptureVideoDataOutput()
//    private let fullResQueue = DispatchQueue(label: "FullResCapture")
    private let fullResFrameHandler = FullResFrameHandler()
    private let frameStripeRenderer = try! FrameStripeRendererBuilder().buildFrameStripeRenderer()
    private var volumeObserver: NSKeyValueObservation?
    private var mtView: MTHKView?
    private var isMixerReady = false

    init() {
        let defaults = UserDefaults.standard

        if let rawValue = defaults.string(forKey: Keys.currentFPS),
           let fps = FPS(rawValue: rawValue) {
            self.currentFPS = fps
        }

        if defaults.object(forKey: Keys.videoBitRates) != nil {
            self.videoBitRates = defaults.double(forKey: Keys.videoBitRates)
        }

        Task { @ScreenActor in
//            videoScreenObject = VideoTrackScreenObject()
            bitStripEffect = BitStripEffect()
//            bitStripEffect?.bandHeightPx = barHeightPx
            bitStripEffect?.bits = StreamSettingsConstants.bits
            bitStripEffect?.framesPerCode = StreamSettingsConstants.framesPerCode
//            if let bit = bitStripEffect {
//                let fps = await mixer.frameRate
//                let per = max(1, Int((Double(fps) / 10.0).rounded()))
//                bit.framesPerCode = per
//            }
        }
    }

    func startPublishing(_ preference: PreferenceViewModel, withRecording: Bool = false) {
        Task {
            guard let session else {
                return
            }
            stats.removeAll()

            let recorder = StreamRecorder()
            await mixer.addOutput(recorder)
            self.recorder = recorder

            if withRecording {
                do {
                    try await recorder.startRecording()
                    isRecording = true
                } catch {
                    self.error = error
                    logger.warn(error)
                }
            }

            do {

                try await session.connect { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if !self.isStopping {
                            self.handleUnexpectedDisconnect(preference)
                        }
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.handleConnectError(error, preference)
                }
            }
        }
    }

    func stopPublishing() {
        Task {
            if isRecording {
                do {
                    if let videoFile = try await recorder?.stopRecording() {
                        Task.detached {
                            try await PHPhotoLibrary.shared().performChanges {
                                let creationRequest = PHAssetCreationRequest.forAsset()
                                creationRequest.addResource(with: .video, fileURL: videoFile, options: nil)
                            }
                        }
                    }
                } catch {
                    logger.warn(error)
                }
                isRecording = false
            }
            if let recorder {
                await mixer.removeOutput(recorder)
                self.recorder = nil
            }
            do {
                try await session?.close()
            } catch {
                logger.error(error)
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            Task {
                do {
                    if let videoFile = try await recorder?.stopRecording() {
                        Task.detached {
                            try await PHPhotoLibrary.shared().performChanges {
                                let creationRequest = PHAssetCreationRequest.forAsset()
                                creationRequest.addResource(with: .video, fileURL: videoFile, options: nil)
                            }
                        }
                    }
                } catch let error as StreamRecorder.Error {
                    switch error {
                    case .failedToFinishWriting(let error):
                        self.error = error
                        if let error {
                            logger.warn(error)
                        }
                    default:
                        self.error = error
                        logger.warn(error)
                    }
                }
                isRecording = false
            }
        } else {
            Task {
                guard let recorder else {
                    logger.warn("Recorder not initialized")
                    return
                }
                do {
                    try await recorder.startRecording()
                    isRecording = true
                } catch {
                    self.error = error
                    logger.warn(error)
                }
                for await error in await recorder.error {
                    switch error {
                    case .failedToAppend(let error):
                        self.error = error
                    default:
                        self.error = error
                    }
                    break
                }
            }
        }
    }

    func toggleAudioMuted() {
        Task {
            if isAudioMuted {
                var settings = await mixer.audioMixerSettings
                var track = settings.tracks[0] ?? .init()
                track.isMuted = false
                settings.tracks[0] = track
                await mixer.setAudioMixerSettings(settings)
                isAudioMuted = false
            } else {
                var settings = await mixer.audioMixerSettings
                var track = settings.tracks[0] ?? .init()
                track.isMuted = true
                settings.tracks[0] = track
                await mixer.setAudioMixerSettings(settings)
                isAudioMuted = true
            }
        }
    }

    func makeSession(_ preference: PreferenceViewModel) async throws {
        // Make session.
        session = try await SessionBuilderFactory.shared.make(preference.makeURL())
            .setMode(.publish)
            .build()

        guard let session else { return }

        let videoSettings = await session.stream.videoSettings
        videoBitRates = Double(videoSettings.bitRate / 1000)
        await session.stream.setBitRateStrategy(StatsMonitor({ data in
            Task { @MainActor in
                self.stats.append(data)
            }
        }))

        let bitRateStrategy = AdaptiveStrategyBuilder().build()
//        let bitRateStrategy = StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: StreamSettingsConstants.maximumVideoBitRate)
        await session.stream.setBitRateStrategy(bitRateStrategy)

        await mixer.addOutput(session.stream)
        tasks.append(Task {
            for await readyState in await session.readyState {
                self.readyState = readyState
                switch readyState {
                case .open:
                    retryCount = 0
                    Task { @MainActor in
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                case .closed:
                    Task { @MainActor in
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                case .connecting, .closing:
                    break
                }
            }
        })

        try await session.stream.setAudioSettings(preference.makeAudioCodecSettings(session.stream.audioSettings))

        var videoCodecSettings = await preference.makeVideoCodecSettings(session.stream.videoSettings)
        videoCodecSettings.videoSize = await mixer.screen.size
        try await session.stream.setVideoSettings(videoCodecSettings)
    }


    func startRunning(_ preference: PreferenceViewModel) {
        Task { @ScreenActor in
            await audioSourceService.setUp()
            await mixer.configuration { session in
                switch audioCaptureMode {
                case .audioSource:
                    session.automaticallyConfiguresApplicationAudioSession = true
                case .audioSourceWithStereo:
                    session.automaticallyConfiguresApplicationAudioSession = false
                case .audioEngine:
                    session.automaticallyConfiguresApplicationAudioSession = true
                }
            }

            // SetUp a mixer.
            await mixer.setSessionPreset(preference.sessionPreset)
            await mixer.setMonitoringEnabled(DeviceUtil.isHeadphoneConnected())
            var videoMixerSettings = await mixer.videoMixerSettings
            videoMixerSettings.mode = .passthrough
            await mixer.setVideoMixerSettings(videoMixerSettings)
            // Attach devices
            let device = await AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: currentPosition)
            if let device {
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = 2
                    if device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
                        device.setPrimaryConstituentDeviceSwitchingBehavior(
                            .restricted,
                            restrictedSwitchingBehaviorConditions: [.videoZoomChanged]
                        )
                    }
                    device.unlockForConfiguration()
                } catch {
                    assertionFailure(error.localizedDescription)
                }
            }

            do {
                try await mixer.attachVideo(device, track: 0) { [weak self] videoUnit in
                    if videoUnit.connection?.isVideoStabilizationSupported == true {
                        videoUnit.preferredVideoStabilizationMode = .standard
                    }
                    if let device = videoUnit.device {
                        do {
                            try device.lockForConfiguration()
                            if device.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                                device.activeColorSpace = .P3_D65     // (або .HLG, залежно від цілей)
                            }
                            if device.isExposureModeSupported(.continuousAutoExposure) {
                                device.exposureMode = .continuousAutoExposure
                            }
                            device.unlockForConfiguration()
                        } catch {
                            self?.showError(error)
                            return
                        }
                    }
                }
            } catch {
                showError(error)
                return
            }

            await mixer.setVideoOrientation(.portrait)

            if await preference.isGPURendererEnabled {
                await mixer.screen.isGPURendererEnabled = true
            } else {
                await mixer.screen.isGPURendererEnabled = false
            }

            let size = StreamSettingsConstants.streamScreenSize
            await mixer.screen.size = .init(width: size.width, height: size.height)
            await mixer.screen.backgroundColor = UIColor.black.cgColor

            if let bit = bitStripEffect {
                _ = await mixer.screen.unregisterVideoEffect(bit)
                _ = await mixer.screen.registerVideoEffect(bit)
            }

            var settings = await mixer.audioMixerSettings
            settings.isMuted = true
            await mixer.setAudioMixerSettings(settings)
            await mixer.setFrameStripeRenderer(frameStripeRenderer: frameStripeRenderer)

//            Task { [weak self] in
//                try? await Task.sleep(for: .seconds(10))
//                let descriptors: [FrameStripeVideoEffectDescriptor] = [
//                    .init { MonochromeEffect() }
//                ]
//                self?.frameStripeRenderer.replaceVideoEffects(descriptors)
//            }
//
//            Task { [weak self] in
//                try? await Task.sleep(for: .seconds(20))
//                self?.frameStripeRenderer.replaceVideoEffects([])
//            }
//
//            Task { [weak self] in
//                try? await Task.sleep(for: .seconds(10))
//                print("🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵🇰🇵")
//                self?.frameStripeRenderer.updateFramesPerCode(15)
//            }
//
//            Task { [weak self] in
//                try? await Task.sleep(for: .seconds(10))
//                print("🚀🚀🚀")
//                self?.frameStripeRenderer.setPhotoMode(.photoModeDisabled)
//            }
//
//            Task { [weak self] in
//                try? await Task.sleep(for: .seconds(20))
//                print("🚀🚀🚀")
//                self?.frameStripeRenderer.setPhotoMode(.photoModeEnabled)
//            }

            await mixer.startRunning()

            isMixerReady = true
            if let mtView {
                await mixer.addOutput(mtView)
            }

            do {
                try await makeSession(preference)
            } catch {
                showError(error)
                return
            }

            await startPublishing(preference)
        }
        Task {
            for await sources in await audioSourceService.sourcesUpdates() {
                audioSources = sources
                if let first = sources.first, audioSource == .empty {
                    audioSource = first
                }
            }
        })
        startVolumeMonitoring()
    }

    @ScreenActor
    private func configureScreen(isGPURendererEnabled: Bool) async {
        await mixer.screen.isGPURendererEnabled = isGPURendererEnabled
        await mixer.screen.size = .init(width: 720, height: 1280)
        await mixer.screen.backgroundColor = UIColor.black.cgColor
    }

    private func startVolumeMonitoring() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)
        isVolumeOn = audioSession.outputVolume > 0
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            Task { @MainActor in
                if let volume = change.newValue {
                    self?.isVolumeOn = volume > 0
                }
            }
        }
    }

    private func stopVolumeMonitoring() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }

    func stopRunning() {
        isMixerReady = false
        stopVolumeMonitoring()
        Task {
            await audioSourceService.stopRunning()
            await mixer.stopRunning()
            try? await mixer.attachAudio(nil)
            try? await mixer.attachVideo(nil, track: 0)
            try? await mixer.attachVideo(nil, track: 1)
            if let session {
                await mixer.removeOutput(session.stream)
            }
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    func flipCamera() {
        Task {
            if await mixer.isMultiCamSessionEnabled {
                var videoMixerSettings = await mixer.videoMixerSettings
                videoMixerSettings.mainTrack = videoMixerSettings.mainTrack == 0 ? 1 : 0
                await mixer.setVideoMixerSettings(videoMixerSettings)
                currentPosition = videoMixerSettings.mainTrack == 0 ? .back : .front
            } else {
                let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
                try? await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)) { [weak self] videoUnit in
                    videoUnit.isVideoMirrored = position == .front
                    if videoUnit.connection?.isVideoStabilizationSupported == true {
                        videoUnit.preferredVideoStabilizationMode = .standard
                    }
                    if let device = videoUnit.device {
                        do {
                            try device.lockForConfiguration()
                            if device.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                                device.activeColorSpace = .P3_D65     // (або .HLG, залежно від цілей)
                            }
                            if device.isExposureModeSupported(.continuousAutoExposure) {
                                device.exposureMode = .continuousAutoExposure
                            }
                            device.unlockForConfiguration()
                        } catch {
                            self?.showError(error)
                            return
                        }
                    }
                }
            }
        }
    }

    func setVisualEffet(_ videoEffect: VideoEffectItem) {
        Task { @ScreenActor in
            if let currentVideoEffect {
                _ = await mixer.screen.unregisterVideoEffect(currentVideoEffect)
            }
            if let videoEffect = videoEffect.makeVideoEffect() {
                currentVideoEffect = videoEffect
                _ = await mixer.screen.registerVideoEffect(videoEffect)
                // Забезпечити, що BitStripEffect застосовується ОСТАННІМ
                if let bit = bitStripEffect {
                    _ = await mixer.screen.unregisterVideoEffect(bit)
                    _ = await mixer.screen.registerVideoEffect(bit)
                }
            }
        }
    }

    func toggleTorch() {
        Task {
            await mixer.setTorchEnabled(!isTorchEnabled)
            isTorchEnabled.toggle()
        }
    }

    func toggleDualCamera() {
        let isEnabled = isDualCameraEnabled
        let position = currentPosition
        Task { @ScreenActor in
            if isEnabled {
                if let videoScreenObject {
                    try? await mixer.screen.removeChild(videoScreenObject)
                }
                await MainActor.run { isDualCameraEnabled = false }
            } else {
                if let videoScreenObject {
                    videoScreenObject.size = .init(width: 400, height: 224)
                    videoScreenObject.cornerRadius = 8.0
                    videoScreenObject.track = position == .front ? 0 : 1
                    videoScreenObject.verticalAlignment = .top
                    videoScreenObject.horizontalAlignment = .right
                    videoScreenObject.layoutMargin = .init(top: 32, left: 0, bottom: 0, right: 32)
                    videoScreenObject.invalidateLayout()
                    try? await mixer.screen.addChild(videoScreenObject)
                }
                await MainActor.run { isDualCameraEnabled = true }
            }
        }
    }

    func setFrameRate(_ fps: Float64) {
        Task {
            do {
                try? await mixer.configuration(video: 0) { video in
                    do {
                        try video.setFrameRate(fps)
                    } catch {
                        logger.error(error)
                    }
                }
                try? await mixer.configuration(video: 1) { video in
                    do {
                        try video.setFrameRate(fps)
                    } catch {
                        logger.error(error)
                    }
                }
                try await mixer.setFrameRate(fps)
                Task { @ScreenActor in
                    bitStripEffect?.framesPerCode = StreamSettingsConstants.framesPerCode
                }
            } catch {
                logger.error(error)
            }
        }
    }

    func orientationDidChange() {
        Task { @ScreenActor in
            if let orientation = await DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
                await mixer.setVideoOrientation(orientation)
            }
            let isLandscape = await UIDevice.current.orientation.isLandscape
            let base = isLandscape ? CGSize(width: 1280, height: 720) : CGSize(width:  720, height: 1280)
            // Канвас: додаємо 30px знизу під смугу
            await mixer.screen.size = .init(width: base.width, height: base.height)

            // Реєструємо ефект на головному відео (разово/ідемпотентно)
            if let bit = bitStripEffect {
                _ = await mixer.screen.unregisterVideoEffect(bit)
                _ = await mixer.screen.registerVideoEffect(bit)
            }
        }
        thermalState = ProcessInfo.processInfo.thermalState
    }

    private func selectAudioSource(_ audioSource: AudioSource) {
        Task {
            try await audioSourceService.selectAudioSource(audioSource)
            await mixer.stopCapturing()
            try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
            await mixer.startCapturing()
        }
    }


    private nonisolated func showError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.error = error
            self?.isShowError = true
        }
    }

    private func handleConnectError(_ error: Error, _ preference: PreferenceViewModel) {

        logger.error(error)
        guard retryCount < maxRetryCount else {
            showError(StreamError.failedStartingSession(error))
            return
        }

        scheduleReconnect(preference)
    }

    private func handleUnexpectedDisconnect(_ preference: PreferenceViewModel) {
        guard !isStopping else { return }         // ми самі зупиняли стрім
        guard reconnectTask == nil else { return } // ще триває попередній retry

        scheduleReconnect(preference)
    }

    private func scheduleReconnect(_ preference: PreferenceViewModel) {
        retryCount += 1
        let delay = pow(2.0, Double(retryCount))      // backoff: 2, 4, 8...

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard
                Task.isCancelled == false,
                let self
            else { return }

            self.reconnectTask = nil
            self.startPublishing(preference)
        }
    }
}

extension PublishViewModel: MTHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: MTHKView) {
        Task { @MainActor in
            self.mtView = view
            if isMixerReady {
                await mixer.addOutput(view)
            }
        }
    }
}


enum StreamError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case failedStartingSession(_ error: Error)

    // MARK: LocalizedError

    public var errorDescription: String? {
        switch self {
        case let .failedStartingSession(error):
            return "failed Starting Session: \(error.localizedDescription)"
        }
    }

    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "")
    }
}

// MARK: - Frame stripe renderer (works with CMSampleBuffer directly)


final class FullResFrameHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    let fullResOutput = AVCaptureVideoDataOutput()
    let fullResQueue = DispatchQueue(label: "FullResCapture")
    private let snapshotWorker: FrameSnapshotWorker? = try? SaveStreamFramesBuilder().buildFrameSnapshotWorker()

    var onFrame: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
//        onFrame?(sampleBuffer)

        print("🔥🔥🔥")
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        print("🔥🔥🔥")

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        print("Full-res frame: \(width)×\(height), format: \(format)")
        
        let index: UInt64 = 102
        let worker = snapshotWorker
        Task {
            await worker?.enqueueJPEG(image: image, codeIndex: index)
        }

        // Тут буфер має ту роздільність, яку задав sessionPreset (1080p, 4K тощо).
        // Можна кодувати хоч у JPEG/HEIC через свій CIContext:
        //   let image = CIImage(cvPixelBuffer: pixelBuffer)
        //   snapshotWorker.enqueueJPEG(image: image, codeIndex: currentCodeIndex)
        //
        // або писати у файл через власний AVAssetWriter.
    }
}



import CoreImage
import CoreGraphics
import AVFoundation
import Synchronization
import os

@available(iOS 18.0, *)
final class FrameCounterIOS18: FrameCounterProtocol, @unchecked Sendable {

    struct FrameThrottleConfig {
        let baselineFramesPerCode: Int
        /// battery 10–20%
        let lowBatteryFramesPerCode: Int
        /// battery <10%
        let criticalBatteryFramesPerCode: Int
        /// thermalState == .fair
        let fairThermalFramesPerCode: Int
        let checkIntervalInFrames: Int
    }

    private let frameCounterData: Mutex<FrameCounterData>
    private var framesUntilCheck: Int
    private let throttleConfig: FrameThrottleConfig

    init(
        frameCounterData: consuming Mutex<FrameCounterData>,
        throttleConfig: FrameThrottleConfig
    ) {
        self.frameCounterData = frameCounterData//Mutex(frameCounterData.copy())
        self.throttleConfig = throttleConfig
        self.framesUntilCheck = throttleConfig.checkIntervalInFrames
    }

    func increment() -> UInt64? {
        let value = frameCounterData.withLock { $0.increment() }

        framesUntilCheck &-= 1
        if framesUntilCheck <= 0 {
            framesUntilCheck = throttleConfig.checkIntervalInFrames
            let config = throttleConfig
            Task { @MainActor [weak self] in
                self?.updateThrottleIfNeeded(config: config)
            }
        }

        return value
    }

    func updateFramesPerCode(_ framesPerCode: Int) {
        frameCounterData.withLock { $0.updateFramesPerCode(framesPerCode) }
    }

    func setPhotoMode(_ mode: StreamSettings) {
        frameCounterData.withLock { $0.setPhotoMode(mode) }
    }

    @MainActor
    private func updateThrottleIfNeeded(config: FrameThrottleConfig) {
        logger.info("🔔 \(config.lowBatteryFramesPerCode)")
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .fair {
            updateFramesPerCode(config.fairThermalFramesPerCode)
        } else {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let battery = UIDevice.current.batteryLevel
            if battery <= 0.1 {
                updateFramesPerCode(config.criticalBatteryFramesPerCode)
            } else if battery <= 0.2 {
                updateFramesPerCode(config.lowBatteryFramesPerCode)
            } else {
                updateFramesPerCode(config.baselineFramesPerCode)
            }
        }
    }
}

final class FrameCounter: FrameCounterProtocol {

    private let frameCounterData: FrameCounterData

    init(frameCounterData: FrameCounterData) {
        self.frameCounterData = frameCounterData
    }

    func increment() -> UInt64? {
        let value = frameCounterData.increment()
        return value
    }

    func updateFramesPerCode(_ framesPerCode: Int) {
        frameCounterData.updateFramesPerCode(framesPerCode)
    }

    func setPhotoMode(_ mode: StreamSettings) {
        frameCounterData.setPhotoMode(mode)
    }
}

protocol FrameCounterProtocol {
    func increment() -> UInt64?
    func updateFramesPerCode(_ framesPerCode: Int)
    func setPhotoMode(_ mode: StreamSettings)
}

final class FrameCounterData {

    private var framesPerCode: Int
    private var sampleCounter: Int
    private var frameIndex: UInt64
    private var photoMode: StreamSettings

    init(
        framesPerCode: Int,
        sampleCounter: Int,
        frameIndex: UInt64,
        photoMode: StreamSettings
    ) {
        self.framesPerCode = framesPerCode
        self.sampleCounter = sampleCounter
        self.frameIndex = frameIndex
        self.photoMode = photoMode
    }

    func increment() -> UInt64? {
        var isNewCode = false
        var fullFrameCode: UInt64 = 0
        if sampleCounter == 0 {
            frameIndex &+= 1
            isNewCode = true

            let codeString = "\(frameIndex)\(photoMode.code)"
            fullFrameCode = UInt64(codeString) ?? frameIndex
        }
        if photoMode.isEnabled {
            sampleCounter = (sampleCounter + 1) % max(1, framesPerCode)
        } else {
            sampleCounter = 1
        }
        return isNewCode ? fullFrameCode : nil
    }

    func updateFramesPerCode(_ framesPerCode: Int) {
        self.framesPerCode = framesPerCode
    }

    func setPhotoMode(_ mode: StreamSettings) {
        photoMode = mode
        sampleCounter = 0
    }
}

struct FrameStripeVideoEffectDescriptor {
    let make: @Sendable () -> VideoEffect
}

struct FrameStripeExposureSettings: Sendable {
    let ev: Float
}

final class SnapshotBufferPool {
    private let pool: CVPixelBufferPool
    private let context: CIContext
    let width: Int
    let height: Int
    let pixelFormat: OSType

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool)
        self.pool = pool!
        self.context = CIContext(options: [.cacheIntermediates: false])
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    func makeCopy(of source: CIImage, colorSpace: CGColorSpace?) -> CVPixelBuffer? {
        logger.info("☠️ START copy")
        defer {
            logger.info("☠️ END copy")
        }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let dest = pixelBufferOut else { return nil }

        let destination = CIRenderDestination(pixelBuffer: dest)
        destination.isFlipped = false
        let _ = try? context.startTask(
            toRender: source,
            from: source.extent,
            to: destination,
            at: .zero
        ).waitUntilCompleted()

        return dest
    }

    func makeCopy(of source: CVPixelBuffer, colorSpace: CGColorSpace?) -> CVPixelBuffer? {
        logger.info("☠️ START copy")
        defer {
            logger.info("☠️ END copy")
        }

        return copyNV12PixelBuffer(from: source, using: pool)
    }

    private func copyNV12PixelBuffer(from source: CVPixelBuffer,
                                     using pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var dest: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest) == kCVReturnSuccess,
              let dest else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])

        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        // Y-plane
        if let srcY = CVPixelBufferGetBaseAddressOfPlane(source, 0),
           let dstY = CVPixelBufferGetBaseAddressOfPlane(dest, 0) {
            let heightY = CVPixelBufferGetHeightOfPlane(source, 0)
            let srcStrideY = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
            let dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(dest, 0)

            if srcStrideY == dstStrideY {
                memcpy(dstY, srcY, heightY * srcStrideY)
            } else {
                for row in 0..<heightY {
                    memcpy(dstY + row * dstStrideY, srcY + row * srcStrideY, min(srcStrideY, dstStrideY))
                }
            }
        }

        // UV-plane
        if let srcUV = CVPixelBufferGetBaseAddressOfPlane(source, 1),
           let dstUV = CVPixelBufferGetBaseAddressOfPlane(dest, 1) {
            let heightUV = CVPixelBufferGetHeightOfPlane(source, 1)
            let srcStrideUV = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
            let dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(dest, 1)

            if srcStrideUV == dstStrideUV {
                memcpy(dstUV, srcUV, heightUV * srcStrideUV)
            } else {
                for row in 0..<heightUV {
                    memcpy(dstUV + row * dstStrideUV, srcUV + row * srcStrideUV, min(srcStrideUV, dstStrideUV))
                }
            }
        }

        return dest
    }
}

final class FrameStripeRenderer: FrameStripeRendererProtocol, @unchecked Sendable {
    // параметри смуги
    private let bandHeightPx: Int = 30
    private let bits: Int = 32
    private let quietCellsEachSide: Int = 0
    private let guardPattern: [UInt8] = []
    private let stripColorSpace = CGColorSpaceCreateDeviceRGB()
    let whiteRGB: SIMD3<Float> = .init(1, 1, 1)
    let blackRGB: SIMD3<Float> = .init(0, 0, 0)
    private lazy var blackCGColor = {
        return CGColor(
            red: CGFloat(blackRGB.x),
            green: CGFloat(blackRGB.y),
            blue: CGFloat(blackRGB.z),
            alpha: 1
        )
    }()
    private lazy var whiteCGColor = {
        return CGColor(
            red: CGFloat(whiteRGB.x),
            green: CGFloat(whiteRGB.y),
            blue: CGFloat(whiteRGB.z),
            alpha: 1
        )
    }()

    var isPhotoModeEnabled: Bool = false

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var effectDescriptors: [FrameStripeVideoEffectDescriptor] = []
    private var effects: [VideoEffect] = []
    private let effectsLock = OSAllocatedUnfairLock()

    private let exposureLock = OSAllocatedUnfairLock()
    private var exposure: FrameStripeExposureSettings?

    // кеш смуги
    private var cachedStrip: CIImage?
    private var cachedWidth = 0
    private var cachedCode: UInt64?

    private let frameCounter: any FrameCounterProtocol

    private let snapshotWorker: FrameSnapshotWorker
    private var snapshotBufferPool: SnapshotBufferPool?

    private let decodeFrameIdentifierUseCase = DecodeFrameIdentifierUseCase()

    init(
        frameCounter: any FrameCounterProtocol,
        snapshotWorker: FrameSnapshotWorker
    ) {
        self.frameCounter = frameCounter
        self.snapshotWorker = snapshotWorker
    }

    /// Накладає смугу на `sampleBuffer`, повертає код кадру (або `nil`, якщо буфер недоступний).

    func renderStripe(on sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        logger.info("⬇️⬇️⬇️ Satrt render")
        defer {
            logger.info("⬆️⬆️⬆️ End render")
        }

        let newCode = frameCounter.increment()
        if let code = newCode {
            cachedCode = code
        }

        guard let codeValue = cachedCode else { return }

        let currentEffects = currentEffects
        let exposureSettings = currentExposureSettings

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if !currentEffects.isEmpty || exposureSettings != nil {
            logger.info("📍 Satrt filters")
            var image = CIImage(cvPixelBuffer: pixelBuffer)

            if let exposureSettings {
                if let filter = CIFilter(name: "CIExposureAdjust") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(exposureSettings.ev, forKey: kCIInputEVKey)
                    image = filter.outputImage ?? image
                }
            }

            for effect in currentEffects {
                image = effect.execute(image)
            }

            ciContext.render(
                image,
                to: pixelBuffer,
                bounds: image.extent,
                colorSpace: nil
            )

            logger.info("📍 End filters")
        }

        if newCode != nil {
            logger.info("📍 Start save snapshot")
            if
                let snapshotPool = actualSnapshotBufferPool(width: width, height: height, pixelFormat: pixelFormat),
                //            let copyPixelBuffer = snapshotPool.makeCopy(of: CIImage(cvPixelBuffer: pixelBuffer), colorSpace: nil)
                let copyPixelBuffer = snapshotPool.makeCopy(of: pixelBuffer, colorSpace: nil)
            {

                let worker = snapshotWorker
                Task.detached(priority: .userInitiated) {
                    await worker.enqueueJPEG(pixelBuffer: copyPixelBuffer, codeIndex: codeValue)
                }
            }
            logger.info("📍 End save snapshot")
        }



        if
            cachedStrip == nil ||
            cachedWidth != width ||
            newCode != nil
        {
            logger.info("📍 Start make strip: \(codeValue)")
            cachedStrip = makeStripImage(width: width,
                                         height: bandHeightPx,
                                         code: codeValue)
            cachedWidth = width
            print("W_W_W codeValue: \(codeValue)")
            logger.info("📍 End make strip")

        } else {
            print("W_W_W --- codeValue: \(codeValue)")
        }

        guard let strip = cachedStrip else { return }

        let translated = strip.transformed(
            by: CGAffineTransform(translationX: 0,
                                  y: 0)
        )

        ciContext.render(
            translated,
            to: pixelBuffer,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: bandHeightPx
            ),
            colorSpace: nil
        )
    }

    private func makeStripImage(
        width: Int,
        height: Int,
        code: UInt64
    ) -> CIImage? {
//        guard width > 0, height > 0 else { return nil }

        var cells: [UInt8] = []
        if quietCellsEachSide > 0 {
            cells.append(contentsOf: Array(repeating: 0, count: quietCellsEachSide))
        }
        if !guardPattern.isEmpty {
            cells.append(contentsOf: guardPattern)
        }

        let dataBits = max(1, bits)
        for i in stride(from: dataBits - 1, through: 0, by: -1) {
            let bit = UInt8((code >> UInt64(i)) & 1)
            cells.append(bit)
        }

        if !guardPattern.isEmpty {
            cells.append(contentsOf: guardPattern)
        }
        if quietCellsEachSide > 0 {
            cells.append(contentsOf: Array(repeating: 0, count: quietCellsEachSide))
        }

        let totalCells = max(1, cells.count)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: stripColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(whiteCGColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cellWidth = CGFloat(width) / CGFloat(totalCells)
        var originX: CGFloat = 0
        for (index, value) in cells.enumerated() {
            let nextX = (index == totalCells - 1) ? CGFloat(width) : min(CGFloat(width), originX + cellWidth)
            if value > 0 {
                let startX = floor(originX)
                ctx.setFillColor(blackCGColor)
                ctx.fill(
                    CGRect(
                        x: startX,
                        y: 0,
                        width: max(1, ceil(nextX) - startX),
                        height: CGFloat(height)
                    )
                )
            }
            originX = nextX
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    func replaceVideoEffects(_ descriptors: [FrameStripeVideoEffectDescriptor]) {
        effectsLock.lock()
        effectDescriptors = descriptors
        effects = descriptors.map { $0.make() }
        effectsLock.unlock()
    }

    private var currentEffects: [VideoEffect] {
        effectsLock.lock()
        defer { effectsLock.unlock() }
        return effects
    }

    func setExposure(_ settings: FrameStripeExposureSettings?) {
        var newSettings = settings
        if let ev = newSettings?.ev {
            let tolerance: Float = 1e-3
            newSettings = abs(ev) < tolerance ? nil : FrameStripeExposureSettings(ev: ev)
        }

        exposureLock.lock()
        exposure = settings
        exposureLock.unlock()
    }

    func updateFramesPerCode(_ framesPerCode: Int) {
        frameCounter.updateFramesPerCode(framesPerCode)
    }

    private var currentExposureSettings: FrameStripeExposureSettings? {
        exposureLock.lock()
        defer { exposureLock.unlock() }
        return exposure
    }

    private func actualSnapshotBufferPool(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> SnapshotBufferPool? {
        if
            snapshotBufferPool == nil
            || snapshotBufferPool?.width != width
            || snapshotBufferPool?.height != height
            || snapshotBufferPool?.pixelFormat != pixelFormat
        {
            snapshotBufferPool = SnapshotBufferPool(width: width, height: height, pixelFormat: pixelFormat)
        }
        return snapshotBufferPool
    }

    func setPhotoMode(_ mode: StreamSettings) {
        frameCounter.setPhotoMode(mode)
    }
}

public final actor AdaptiveBitRateStrategy: StreamBitRateStrategy {

    public let mamimumVideoBitRate: Int          // hard max
    public let mamimumAudioBitRate: Int
    private let defaultVideoBitRate: Int         // використовується на reset
    private let minVideoBitRate: Int             // floor
    private let increaseThreshold: Int           // скільки status підряд для підвищення
    private let increaseStep: Int                // крок підвищення
    private let learnDownFactor: Double          // множник для зниження currentMax (напр. 0.9)
    private let learnUpFactor: Double            // множник для підняття currentMax після стабільності (напр. 1.05)
    private let stableForLearnUp: Int            // скільки status підряд для підняття currentMax

    private var currentMax: Int
    private var sufficientBWCounts = 0
    private var zeroBytesOutPerSecondCounts = 0
    private var stableCountsForCeiling = 0

    private let isDataRateLimitsEnable: Bool

    public init(
        mamimumVideoBitrate: Int,
        defaultVideoBitrate: Int,
        minVideoBitrate: Int,
        mamimumAudioBitRate: Int,
        increaseThreshold: Int,
        increaseStep: Int,                 // якщо nil → 10% від hard max
        learnDownFactor: Double,
        learnUpFactor: Double,
        stableForLearnUp: Int,               // скільки status підряд без проблем, щоб підняти currentMax
        isDataRateLimitsEnable: Bool
    ) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
        self.defaultVideoBitRate = min(defaultVideoBitrate, mamimumVideoBitrate)
        self.minVideoBitRate = minVideoBitrate
        self.mamimumAudioBitRate = mamimumAudioBitRate
        self.increaseThreshold = increaseThreshold
        self.increaseStep = increaseStep
        self.learnDownFactor = learnDownFactor
        self.learnUpFactor = learnUpFactor
        self.stableForLearnUp = stableForLearnUp
        self.currentMax = mamimumVideoBitrate
        self.isDataRateLimitsEnable = isDataRateLimitsEnable
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            stableCountsForCeiling += 1
            if stableCountsForCeiling >= stableForLearnUp {
                currentMax = min(Int(Double(currentMax) * learnUpFactor), mamimumVideoBitRate)
                stableCountsForCeiling = 0
                logger.info("AB: status: increasing max to \(currentMax)")
            }
            var video = await stream.videoSettings
            if video.bitRate < currentMax {
                if sufficientBWCounts >= increaseThreshold {
                    let oldBitRate = video.bitRate
                    video.bitRate = min(video.bitRate + increaseStep, currentMax)
                    sufficientBWCounts = 0

                    if video.bitRate != oldBitRate {
                        if isDataRateLimitsEnable {
                            video.dataRateLimits = calculateDataRateLimits(from: video)
                        }
                        try? await stream.setVideoSettings(video)
                        logger.info("AB: status: update video bitrate from \(oldBitRate) to \(video.bitRate) || mode: \(video.bitRateMode)")
                    } else {
                        logger.info("AB: already MAXIMUM")
                    }
                } else {
                    sufficientBWCounts += 1
                    logger.info("AB: status: increment sufficientBWCounts to \(sufficientBWCounts)")
                }
            } else {
                sufficientBWCounts = 0
                logger.info("AB: status: reset sufficientBWCounts")
            }

        case .publishInsufficientBWOccured(let report):
            stableCountsForCeiling = 0
            sufficientBWCounts = 0

            var video = await stream.videoSettings
            let audio = await stream.audioSettings
            let newCeiling = Int(Double(video.bitRate) * learnDownFactor)

            if report.currentBytesOutPerSecond > 0 {
                var candidate = Int(report.currentBytesOutPerSecond * 8) / (zeroBytesOutPerSecondCounts + 1)
                if zeroBytesOutPerSecondCounts == 0 {
                    candidate = Int(Double(candidate) * learnDownFactor)
                    logger.info("AB: first zeroBytesOutPerSecondCounts")
                }
                let target = max(candidate - audio.bitRate, minVideoBitRate)
                video.bitRate = max(target, minVideoBitRate)
                video.frameInterval = 0.0
                zeroBytesOutPerSecondCounts = 0
                currentMax = max(video.bitRate, newCeiling, minVideoBitRate)

                logger.info("AB: publishInsufficientBWOccured: update video bitrate to \(video.bitRate) | report.currentBytesOutPerSecond * 8: \(report.currentBytesOutPerSecond * 8) | target: \(target) | candidate: \(candidate)")
            } else {
                switch zeroBytesOutPerSecondCounts {
                case 2: video.frameInterval = VideoCodecSettings.frameInterval10
                case 4: video.frameInterval = VideoCodecSettings.frameInterval05
                default: break
                }
                zeroBytesOutPerSecondCounts += 1
                logger.info("AB: publishInsufficientBWOccured: increment zeroBytesOutPerSecondCounts to \(zeroBytesOutPerSecondCounts). video.frameInterval: \(video.frameInterval)")
            }
            // знизити adaptive ceiling
//            currentMax = max(video.bitRate, newCeiling, minVideoBitRate)

            if isDataRateLimitsEnable {
                video.dataRateLimits = calculateDataRateLimits(from: video)
            }
            try? await stream.setVideoSettings(video)
            logger.info("AB: publishInsufficientBWOccured: update currentMax to \(currentMax) | newCeiling: \(newCeiling) | video.bitRate: \(video.bitRate)")

        case .reset:
            sufficientBWCounts = 0
            zeroBytesOutPerSecondCounts = 0
            stableCountsForCeiling = 0
            currentMax = mamimumVideoBitRate
            var video = await stream.videoSettings
            if video.bitRate != defaultVideoBitRate {
                video.bitRate = defaultVideoBitRate
                logger.info("AB: RESET!!!🔴🔴🔴")
                if isDataRateLimitsEnable {
                    video.dataRateLimits = calculateDataRateLimits(from: video)
                }
                try? await stream.setVideoSettings(video)
            }
        }
    }

    func calculateDataRateLimits(from videoSettings: VideoCodecSettings) -> [Double]? {
        return [Double(videoSettings.bitRate) / 8 * 1.5, 1.0]
    }
}

struct FrameStripeRendererBuilder {

    func buildFrameStripeRenderer() throws -> FrameStripeRenderer {
        let frameCounter: any FrameCounterProtocol
        if #available(iOS 18.0, *) {
            let frameCounterData: Mutex<FrameCounterData> = .init(
                FrameCounterData(
                    framesPerCode: StreamSettingsConstants.framesPerCode,
                    sampleCounter: 0,
                    frameIndex: 0,
                    photoMode: .photoModeEnabled
                )
            )
            let throttleConfig = FrameCounterIOS18.FrameThrottleConfig(
                baselineFramesPerCode: StreamSettingsConstants.framesPerCode,
                lowBatteryFramesPerCode: StreamSettingsConstants.lowBatteryFramesPerCode,
                criticalBatteryFramesPerCode: StreamSettingsConstants.criticalBatteryFramesPerCode,
                fairThermalFramesPerCode: StreamSettingsConstants.fairThermalFramesPerCode,
                checkIntervalInFrames: StreamSettingsConstants.checkIntervalInFrames
            )
            frameCounter = FrameCounterIOS18(
                frameCounterData: frameCounterData,
                throttleConfig: throttleConfig
            )
        } else {
            let frameCounterData = FrameCounterData(
                framesPerCode: StreamSettingsConstants.framesPerCode,
                sampleCounter: 0,
                frameIndex: 0,
                photoMode: .photoModeEnabled
            )
            frameCounter = FrameCounter(frameCounterData: frameCounterData)
        }
        let snapshotWorker = try SaveStreamFramesBuilder().buildFrameSnapshotWorker()
        return FrameStripeRenderer(
            frameCounter: frameCounter,
            snapshotWorker: snapshotWorker
        )
    }
}


struct AdaptiveStrategyBuilder {

    func build() -> AdaptiveBitRateStrategy {
        return AdaptiveBitRateStrategy(
            mamimumVideoBitrate: StreamSettingsConstants.maximumVideoBitRate,
            defaultVideoBitrate: StreamSettingsConstants.defaultVideoBitRate,
            minVideoBitrate: StreamSettingsConstants.minimumVideoBitRate,
            mamimumAudioBitRate: StreamSettingsConstants.defaultAudioBitRate,
            increaseThreshold: StreamSettingsConstants.increaseThresholdAdaptiveBitRate,
            increaseStep: StreamSettingsConstants.increaseStepAdaptiveBitRate,
            learnDownFactor: StreamSettingsConstants.learnDownFactorAdaptiveBitRate,
            learnUpFactor: StreamSettingsConstants.learnUpFactorAdaptiveBitRate,
            stableForLearnUp: StreamSettingsConstants.stableForLearnUpAdaptiveBitRate,
            isDataRateLimitsEnable: StreamSettingsConstants.isDataRateLimitsEnable
        )
    }
}
