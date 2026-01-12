import CoreImage
import CoreGraphics
import UIKit
import HaishinKit
import AVFoundation

// MARK: - Stream settings code (suffix)
public enum StreamSettings: String, Sendable {
    case photoModeEnabled  = "01"
    case photoModeDisabled = "02"

    public var code: String { rawValue }
    public var isEnabled: Bool { self == .photoModeEnabled }
}

final class BitStripEffect: VideoEffect {

    // MARK: — налаштування стрічки
    var bandHeightPx: Int = 30
    var bits: Int = StreamSettingsConstants.bits
    var framesPerCode: Int = 3 { didSet { framesPerCode = max(1, framesPerCode) } }
    var drawAtTop = false
    var whiteRGB: SIMD3<Float> = .init(1, 1, 1)
    var blackRGB: SIMD3<Float> = .init(0, 0, 0)
    var quietCellsEachSide: Int = 0
    var guardPattern: [UInt8] = []

    // “photo mode” (додає два десяткові символи в кінець коду)
    var isPhotoModeEnabled: Bool = false {
        didSet { cachedStrip = nil }
    }
    private func suffixCode() -> String {
        isPhotoModeEnabled ? "01" : "02"
    }

    // MARK: — стан нумерації
    private var frameCount = 0
    private var codeIndex: UInt64 = 0
    private var cachedStrip: CIImage?
    private var cachedStripWidth = 0
    private var cachedStripHeight = 0
    private var cachedStripCode: UInt64 = 0
    private var cachedStripBits = 0
    private var cachedStripQuiet = 0
    private var cachedStripGuard: [UInt8] = []
    private var cachedStripWhite: SIMD3<Float> = .init(1, 1, 1)
    private var cachedStripBlack: SIMD3<Float> = .init(0, 0, 0)

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let snapshotWorker = try? SaveStreamFramesBuilder().buildFrameSnapshotWorker()

    private var sampleCounter: Int = 0
    private var frameIndex: UInt64 = 0

    func execute(_ image: CIImage) -> CIImage {

        var fullFrameCode: UInt64 = 0
        if sampleCounter == 0 {
            frameIndex &+= 1

            let codeString = "\(frameIndex)\(suffixCode())"
            fullFrameCode = UInt64(codeString) ?? frameIndex
            cachedStripCode = fullFrameCode
        }
        sampleCounter = (sampleCounter + 1) % max(1, framesPerCode)
        logger.info("🤡🤡🤡 FRAME: \(cachedStripCode)")
        return image
        // оновлюємо код раз на framesPerCode кадрів
        if frameCount == 0 {
            codeIndex &+= 1
            cachedStrip = nil

            let decimal = "\(codeIndex)\(suffixCode())"
            let stripCode = UInt64(decimal) ?? codeIndex

            if let worker = snapshotWorker {
                Task { await worker.enqueueJPEG(image: image, codeIndex: stripCode) }
            }
            cachedStripCode = stripCode
        }
        frameCount &+= 1
        if frameCount >= framesPerCode { frameCount = 0 }

        // намагаємось намалювати смугу напряму у вихідний pixelBuffer
        if drawStripInPlace(on: image, code: cachedStripCode) {
            return image          // smuha вже накреслена в буфері
        } else if let strip = makeStripImage(width: Int(image.extent.width),
                                             height: bandHeightPx,
                                             code: cachedStripCode) {
            // fallback: compositing (тимчасово, коли немає доступу до pixelBuffer)
            let y = drawAtTop ? (image.extent.maxY - CGFloat(bandHeightPx)) : image.extent.minY
            return strip
                .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: y))
                .composited(over: image)
        } else {
            return image
        }
    }

    // MARK: — малювання смуги безпосередньо у CVPixelBuffer

    private func drawStripInPlace(on image: CIImage, code: UInt64) -> Bool {
        guard let pixelBuffer = extractPixelBuffer(from: image),
              CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            return false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }

        if cachedStrip == nil ||
            cachedStripWidth != width ||
            cachedStripHeight != bandHeightPx ||
            cachedStripCode != code ||
            cachedStripBits != bits ||
            cachedStripQuiet != quietCellsEachSide ||
            cachedStripGuard != guardPattern ||
            cachedStripWhite != whiteRGB ||
            cachedStripBlack != blackRGB {

            cachedStrip = makeStripImage(width: width,
                                         height: bandHeightPx,
                                         code: code)
            cachedStripWidth = width
            cachedStripHeight = bandHeightPx
            cachedStripCode = code
            cachedStripBits = bits
            cachedStripQuiet = quietCellsEachSide
            cachedStripGuard = guardPattern
            cachedStripWhite = whiteRGB
            cachedStripBlack = blackRGB
        }

        guard let strip = cachedStrip else { return false }

        let dest = CIRenderDestination(pixelBuffer: pixelBuffer)
        dest.isFlipped = false

        let targetY = drawAtTop ? CGFloat(height - bandHeightPx) : 0
        do {
            try ciContext.startTask(
                toRender: strip,
                from: strip.extent,
                to: dest,
                at: CGPoint(x: 0, y: targetY)
            )
        } catch {
            return false
        }
        return true
    }

    // MARK: — генерація смуги

//    private func extractPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
//        if let buffer = image.value(forKey: "pixelBuffer") as? CVPixelBuffer {
//            return buffer
//        }
//        return nil
//    }
    private func extractPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        guard let raw = image.value(forKey: "pixelBuffer") else { return nil }
        let cfObject = raw as AnyObject
        guard CFGetTypeID(cfObject) == CVPixelBufferGetTypeID() else { return nil }
        return raw as! CVPixelBuffer
    }

    private func makeStripImage(width: Int,
                                height: Int,
                                code: UInt64) -> CIImage? {
        guard width > 0, height > 0 else { return nil }

        var cells: [UInt8] = []
        if quietCellsEachSide > 0 { cells += Array(repeating: 0, count: quietCellsEachSide) }
        if !guardPattern.isEmpty { cells += guardPattern }

        let bitCount = max(1, bits)
        for i in stride(from: bitCount - 1, through: 0, by: -1) {
            let bit = UInt8((code >> UInt64(i)) & 1)
            cells.append(bit)
        }

        if !guardPattern.isEmpty { cells += guardPattern }
        if quietCellsEachSide > 0 { cells += Array(repeating: 0, count: quietCellsEachSide) }

        let totalCells = max(1, cells.count)
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let black = CGColor(red: CGFloat(blackRGB.x), green: CGFloat(blackRGB.y), blue: CGFloat(blackRGB.z), alpha: 1)
        let white = CGColor(red: CGFloat(whiteRGB.x), green: CGFloat(whiteRGB.y), blue: CGFloat(whiteRGB.z), alpha: 1)

        ctx.setFillColor(black)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cellWidth = CGFloat(width) / CGFloat(totalCells)
        var originX: CGFloat = 0
        for (index, value) in cells.enumerated() {
            let nextX = (index == totalCells - 1) ? CGFloat(width) : min(CGFloat(width), originX + cellWidth)
            if value > 0 {
                ctx.setFillColor(white)
                ctx.fill(CGRect(x: floor(originX),
                                y: 0,
                                width: max(1, ceil(nextX) - floor(originX)),
                                height: CGFloat(height)))
            }
            originX = nextX
        }

        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }
}

//final class BitStripEffect: VideoEffect {
//    // MARK: - Параметри
//    var bandHeightPx: CGFloat = StreamSettingsConstants.bandHeightPx
//    var bits: Int = StreamSettingsConstants.bits
//    var framesPerCode: Int = StreamSettingsConstants.framesPerCode { didSet { framesPerCode = max(1, framesPerCode) } }
//    var drawAtTop: Bool = false
//    var whiteRGB: SIMD3<Float> = .init(1, 1, 1)
//    var blackRGB: SIMD3<Float> = .init(0, 0, 0)
//    // Додаткові службові пікселі: тихі зони і guard-патерн для кращої стабільності/детекції
//    var quietCellsEachSide: Int = 0//4
//    var guardPattern: [UInt8] = []//[1, 0, 1, 0, 1, 0]
//
//    // MARK: - Photo mode flag (affects 2-char suffix code)
//    public var isPhotoModeEnabled: Bool = false { didSet { cachedStrip = nil } }
//    public func codeForMakePhotoOpportunity() -> String {
//        isPhotoModeEnabled ? StreamSettings.photoModeEnabled.code : StreamSettings.photoModeDisabled.code
//    }
//
//    // MARK: - Стан
//    private var frameCount = 0
//    private var codeIndex: UInt64 = 0
//    private var currentCodeValue: UInt64 = 0
//    private var cachedStrip: CIImage?
//    private var cachedStripWidth: Int = 0
//    private var cachedStripHeight: Int = 0
//    private var cachedStripCode: UInt64 = 0
//    private var cachedStripBits: Int = 0
//    private var cachedStripQuiet: Int = 0
//    private var cachedStripGuard: [UInt8] = []
//    private var cachedStripWhite: SIMD3<Float> = .init(1, 1, 1)
//    private var cachedStripBlack: SIMD3<Float> = .init(0, 0, 0)
//
//
//    private let snapshotWorker: FrameSnapshotWorker? = try? SaveStreamFramesBuilder().buildFrameSnapshotWorker()
//
//    func execute(_ image: CIImage) -> CIImage {
//        // Інкрементуємо код раз на N кадрів
//        if frameCount == 0 {
//            codeIndex &+= 1
//            let decimalString = "\(codeIndex)\(codeForMakePhotoOpportunity())"
//            currentCodeValue = UInt64(decimalString) ?? codeIndex
//            cachedStripCode = 0 // invalidate cache
//
//            let index = currentCodeValue
//            if let worker = snapshotWorker {
//                Task { await worker.enqueueJPEG(image: image, codeIndex: index) }
//            }
//        }
//        frameCount &+= 1
//        if frameCount >= framesPerCode { frameCount = 0 }
//
//        let src = image.extent
//        let bandHeight = Int(max(1, bandHeightPx.rounded()))
//        let width = Int(src.width.rounded(.down))
//        guard width > 0 else { return image }
//
//        if cachedStrip == nil ||
//            cachedStripWidth != width ||
//            cachedStripHeight != bandHeight ||
//            cachedStripCode != currentCodeValue ||
//            cachedStripBits != bits ||
//            cachedStripQuiet != quietCellsEachSide ||
//            cachedStripGuard != guardPattern ||
//            cachedStripWhite != whiteRGB ||
//            cachedStripBlack != blackRGB {
//            cachedStrip = Self.makeStripImage(
//                code: currentCodeValue,
//                width: width,
//                height: bandHeight,
//                bits: bits,
//                quietCellsEachSide: quietCellsEachSide,
//                guardPattern: guardPattern,
//                whiteRGB: whiteRGB,
//                blackRGB: blackRGB
//            )
//            cachedStripWidth = width
//            cachedStripHeight = bandHeight
//            cachedStripCode = currentCodeValue
//            cachedStripBits = bits
//            cachedStripQuiet = quietCellsEachSide
//            cachedStripGuard = guardPattern
//            cachedStripWhite = whiteRGB
//            cachedStripBlack = blackRGB
//        }
//
//        guard let strip = cachedStrip else { return image }
//
//        let bandY = drawAtTop ? (src.maxY - CGFloat(bandHeight)) : src.minY
//        let translated = strip.transformed(by: .init(translationX: src.minX, y: bandY))
//        logger.info("W_W_W \(currentCodeValue)")
//        return translated.composited(over: image)
//    }
//
//    private static func makeStripImage(
//        code: UInt64,
//        width: Int,
//        height: Int,
//        bits: Int,
//        quietCellsEachSide: Int,
//        guardPattern: [UInt8],
//        whiteRGB: SIMD3<Float>,
//        blackRGB: SIMD3<Float>
//    ) -> CIImage? {
//        guard width > 0, height > 0 else { return nil }
//
//        let dataBits = max(1, bits)
//        var cells = [UInt8]()
//        if quietCellsEachSide > 0 {
//            cells.append(contentsOf: Array(repeating: 0, count: quietCellsEachSide))
//        }
//        if !guardPattern.isEmpty {
//            cells.append(contentsOf: guardPattern)
//        }
//        for i in stride(from: dataBits - 1, through: 0, by: -1) {
//            let bit = UInt8((code >> UInt64(i)) & 1)
//            cells.append(bit)
//        }
//        if !guardPattern.isEmpty {
//            cells.append(contentsOf: guardPattern)
//        }
//        if quietCellsEachSide > 0 {
//            cells.append(contentsOf: Array(repeating: 0, count: quietCellsEachSide))
//        }
//
//        let totalCells = max(1, cells.count)
//        let colorSpace = CGColorSpaceCreateDeviceRGB()
//        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
//
//        guard let ctx = CGContext(
//            data: nil,
//            width: width,
//            height: height,
//            bitsPerComponent: 8,
//            bytesPerRow: 0,
//            space: colorSpace,
//            bitmapInfo: bitmapInfo
//        ) else { return nil }
//
//        let blackColor = CGColor(red: CGFloat(blackRGB.x), green: CGFloat(blackRGB.y), blue: CGFloat(blackRGB.z), alpha: 1)
//        let whiteColor = CGColor(red: CGFloat(whiteRGB.x), green: CGFloat(whiteRGB.y), blue: CGFloat(whiteRGB.z), alpha: 1)
//
//        ctx.setFillColor(blackColor)
//        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
//
//        let cellWidth = CGFloat(width) / CGFloat(totalCells)
//        var originX: CGFloat = 0
//        for (index, value) in cells.enumerated() {
//            let nextX = (index == totalCells - 1) ? CGFloat(width) : min(CGFloat(width), originX + cellWidth)
//            if value > 0 {
//                let startX = floor(originX)
//                let rect = CGRect(x: startX, y: 0, width: max(1, ceil(nextX) - startX), height: CGFloat(height))
//                ctx.setFillColor(whiteColor)
//                ctx.fill(rect)
//            }
//            originX = nextX
//        }
//
//        guard let image = ctx.makeImage() else { return nil }
//        return CIImage(cgImage: image)
//    }
//
//    func decodeFrameNumberString(
//        from output: CIImage,
//        bits: Int = 32,
//        quiet: Int = 4,
//        guardPattern: [Int] = [1, 0, 1, 0, 1, 0],
//        bandHeight: CGFloat = 30,
//        isTop: Bool = false,
//        threshold: CGFloat = 0.5,
//        context: CIContext
//    ) -> String? {
//        let extent = output.extent
//        guard extent.width > 1, extent.height > 1 else { return nil }
//
//        // 1) Прямокутник смуги (знизу або зверху)
//        let bandH = min(bandHeight, extent.height)
//        let bandRect: CGRect = isTop
//            ? .init(x: extent.minX, y: extent.maxY - bandH, width: extent.width, height: bandH)
//            : .init(x: extent.minX, y: extent.minY,          width: extent.width, height: bandH)
//
//        // 2) Загальна кількість клітинок
//        let cellsTotal = quiet * 2 + guardPattern.count * 2 + bits
//        guard cellsTotal > 0 else { return nil }
//
//        // Невеликі відступи від меж клітин і по висоті, щоб уникати країв/шуму
//        let cellW = bandRect.width / CGFloat(cellsTotal)
//        let marginX = max(0.0, cellW * 0.15)
//        let marginY = max(0.0, bandRect.height * 0.30)
//
//        // 3) Допоміжна: середня яскравість прямокутника
//        func averageLuma(_ rect: CGRect) -> CGFloat {
//            guard let filter = CIFilter(name: "CIAreaAverage") else { return 1.0 }
//            filter.setValue(output, forKey: kCIInputImageKey)
//            filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
//            guard let onePixel = filter.outputImage else { return 1.0 }
//
//            var rgba = [UInt8](repeating: 0, count: 4)
//            context.render(
//                onePixel,
//                toBitmap: &rgba,
//                rowBytes: 4,
//                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                format: .RGBA8,
//                colorSpace: CGColorSpaceCreateDeviceRGB()
//            )
//            let r = CGFloat(rgba[0]) / 255.0
//            let g = CGFloat(rgba[1]) / 255.0
//            let b = CGFloat(rgba[2]) / 255.0
//            return 0.2126 * r + 0.7152 * g + 0.0722 * b
//        }
//
//        // 4) Зняти луми по центру комірок
//        var lumas: [CGFloat] = []
//        lumas.reserveCapacity(cellsTotal)
//        for i in 0..<cellsTotal {
//            let x0 = bandRect.minX + CGFloat(i) * cellW + marginX
//            let x1 = bandRect.minX + CGFloat(i + 1) * cellW - marginX
//            let y0 = bandRect.minY + marginY
//            let y1 = bandRect.maxY - marginY
//            let sampleRect = CGRect(
//                x: max(x0, bandRect.minX),
//                y: max(y0, bandRect.minY),
//                width: max(1.0, x1 - x0),
//                height: max(1.0, y1 - y0)
//            )
//            lumas.append(averageLuma(sampleRect))
//        }
//
//        // 4.1) Динамічний поріг (якщо threshold < 0): ітеративна схема Ridler–Calvard
//        let thr: CGFloat = {
//            if threshold >= 0 { return threshold }
//            guard let minL = lumas.min(), let maxL = lumas.max() else { return 0.5 }
//            var t = (minL + maxL) * 0.5
//            for _ in 0..<6 {
//                var sum0: CGFloat = 0, cnt0: CGFloat = 0
//                var sum1: CGFloat = 0, cnt1: CGFloat = 0
//                for v in lumas {
//                    if v < t { sum1 += v; cnt1 += 1 } else { sum0 += v; cnt0 += 1 }
//                }
//                if cnt0 == 0 || cnt1 == 0 { break }
//                let m0 = sum0 / max(cnt0, 1)
//                let m1 = sum1 / max(cnt1, 1)
//                let nt = (m0 + m1) * 0.5
//                if abs(nt - t) < 1e-3 { t = nt; break }
//                t = nt
//            }
//            return t
//        }()
//
//        // 4.2) Перетворити у біти: білий=0, чорний=1
//        var cells: [Int] = []
//        cells.reserveCapacity(cellsTotal)
//        for v in lumas {
//            cells.append(v < thr ? 1 : 0)
//        }
//
//        // 5) Виділити дані (MSB→LSB)
//        let g = guardPattern.count
//        let dataStart = quiet + g
//        let dataEnd = dataStart + bits
//        guard dataEnd <= cells.count else { return nil }
//        let dataBits = cells[dataStart..<dataEnd]
//
//        // 6) Зібрати число з бітів (MSB ліворуч)
//        var value: UInt64 = 0
//        for b in dataBits {
//            value = (value << 1) | (b == 1 ? 1 : 0)
//        }
//        return String(value)
//    }
//}



//final class BitStripEffect: VideoEffect {
//    // MARK: - Параметри
//    var bandHeightPx: CGFloat = StreamSettingsConstants.bandHeightPx
//    var bits: Int = StreamSettingsConstants.bits
//    var framesPerCode: Int = StreamSettingsConstants.framesPerCode { didSet { framesPerCode = max(1, framesPerCode) } }
//    var drawAtTop: Bool = false
//    var whiteRGB: SIMD3<Float> = .init(1, 1, 1)
//    var blackRGB: SIMD3<Float> = .init(0, 0, 0)
//    // Додаткові службові пікселі: тихі зони і guard-патерн для кращої стабільності/детекції
//    var quietCellsEachSide: Int = 0//4
//    var guardPattern: [UInt8] = []//[1, 0, 1, 0, 1, 0]
//
//    // MARK: - Photo mode flag (affects 2-char suffix code)
//    public var isPhotoModeEnabled: Bool = false { didSet { needsMaskRebuild = true } }
//    public func codeForMakePhotoOpportunity() -> String {
//        isPhotoModeEnabled ? StreamSettings.photoModeEnabled.code : StreamSettings.photoModeDisabled.code
//    }
//
//    // MARK: - Стан
//    private var frameCount = 0
//    private var codeIndex: UInt64 = 0
//    private var needsMaskRebuild = true
//    private var cachedMask: CIImage?
//
//    private lazy var kernelUnder: CIKernel? = Self.loadKernel(named: "bandMaskUnder")
//    private lazy var kernelOverlay: CIKernel? = Self.loadKernel(named: "bandMaskOverlay")
//
//
//    private let snapshotWorker: FrameSnapshotWorker? = try? SaveStreamFramesBuilder().buildFrameSnapshotWorker()
//
//    func execute(_ image: CIImage) -> CIImage {
//        let usingUnder = (kernelUnder != nil)
//        guard let kernel = usingUnder ? kernelUnder : kernelOverlay else { return image }
//
//        var fullFrameCode: UInt64 = 0
//
//        // Інкрементуємо код раз на N кадрів
//        if frameCount == 0 {
//            codeIndex &+= 1
//            needsMaskRebuild = true
//
////            snapshotWorker.enqueueJPEG(image: image, codeIndex: codeIndex)
//            let decimalString = "\(codeIndex)\(codeForMakePhotoOpportunity())"
//            fullFrameCode = UInt64(decimalString) ?? 0
//            let index = fullFrameCode
//            let worker = snapshotWorker
//            Task {
//                await worker?.enqueueJPEG(image: image, codeIndex: index)
//            }
//
//            // Зберегти кадр без смуги рівно раз на код, уникаючи передавання CIImage між виконавцями:
////            let opts: [CIImageRepresentationOption: Any] = [
////                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7
////            ]
////            
////            if let jpeg = snapshotContext.jpegRepresentation(of: image, colorSpace: snapshotColorSpace, options: opts) {
////                let current = codeIndex
////                Task {
////                    await LastFramesStore.shared.storeJPEG(jpeg, codeIndex: current)
////                }
////            }
//        }
//        frameCount &+= 1
//        if frameCount >= framesPerCode { frameCount = 0 }
//
//        if needsMaskRebuild || cachedMask == nil {
//            // Формуємо десятковий рядок: frameNumber + 2-символьний суфікс режиму
//
//            cachedMask = Self.buildMaskImage(
//                bits: bits,
//                code: fullFrameCode,
//                quietCellsEachSide: quietCellsEachSide,
//                guardPattern: guardPattern
//            )
//            needsMaskRebuild = false
//        }
//        guard let mask = cachedMask else { return image }
//
//        let src = image.extent
//        let bandH = max(1, bandHeightPx)
//        // Позиція смуги: для overlay — всередині вихідного кадру;
//        // для under — параметр не використовується ядром, але передаємо для узгодженості.
//        let bandY: CGFloat = {
//            if usingUnder {
//                return drawAtTop ? (src.minY + src.height) : src.minY
//            } else {
//                // overlay: смуга в межах src
//                return drawAtTop ? (src.minY + src.height - bandH) : src.minY
//            }
//        }()
//
//        // Розміри для ядра
//        let widthPx = Float(src.width)
//        let heightPx = Float(src.height)
//        let bandYF = Float(bandY)
//        let bandHF = Float(bandH)
//
//        // Вихідний extent
//        let outExtent: CGRect = usingUnder
//        ? CGRect(x: src.minX, y: src.minY, width: src.width, height: src.height + bandH) // "під" відео
//        : src // overlay поверх
//
//        // ROI: під різні ядра різна стратегія
//        let roi: CIKernelROICallback = { index, rect in
//            if index == 0 {
//                if usingUnder {
//                    // Ядро семплить src при y - bandH, тому ROI зміщуємо вниз і обрізаємо
//                    let shifted = rect.offsetBy(dx: 0, dy: -bandH)
//                    return shifted.intersection(src)
//                } else {
//                    // overlay: семплим в межах rect
//                    return rect
//                }
//            } else {
//                return mask.extent
//            }
//        }
//
//        // Кількість клітинок (quiet | guard | data | guard | quiet)
//        let cellsTotal = quietCellsEachSide * 2 + guardPattern.count * 2 + bits
//
//        let args: [Any] = [
//            image,
//            mask,
//            widthPx, heightPx,
//            bandYF, bandHF,
//            Float(cellsTotal),
//            whiteRGB.x, whiteRGB.y, whiteRGB.z,
//            blackRGB.x, blackRGB.y, blackRGB.z,
//            Float(outExtent.minX), Float(outExtent.width)
//        ]
//        //print("Code index: \(codeIndex)")
//        logger.info("Code index: \(codeIndex)")
//let outputImage = kernel.apply(extent: outExtent, roiCallback: roi, arguments: args) ?? image
////        if let frameStr = decodeFrameNumberString(from: outputImage,
////                                                  bits: bits,
////                                                  quiet: quietCellsEachSide,
////                                                  guardPattern: guardPattern.map(Int.init),
////                                                  bandHeight: bandHeightPx,
////                                                  isTop: drawAtTop,
////                                                  threshold: -1.0, //  щоб завжди використовувався динамічний поріг.
////                                                  context: sharedCIContext
////        ) {
//////            print("Frame \(frameStr)")
////            logger.info("Frame \(frameStr)")
////        }
//
//
//        return outputImage
//    }
//
//    // Локальний контекст для JPEG-снапшоту (безпечний для меж акторів)
//    private lazy var snapshotContext = CIContext(options: [.cacheIntermediates: false])
//    private let snapshotColorSpace = CGColorSpaceCreateDeviceRGB()
//    // MARK: - Kernel loading
//    private static func loadKernel(named fn: String) -> CIKernel? {
//        // Підвантаження з твого бандла (не SPM)
//        let candidates: [Bundle] = [
//            Bundle(for: BitStripEffect.self),
//            Bundle.main
//        ]
//        for b in candidates {
//            if let url = b.url(forResource: "default", withExtension: "metallib"),
//               let data = try? Data(contentsOf: url),
//               let k = try? CIKernel(functionName: fn, fromMetalLibraryData: data) {
//                return k
//            }
//        }
//        return nil
//    }
//
//    // MARK: - Маска 1×cells (quiet | guard | data(MSB→LSB) | guard | quiet)
//    private static func buildMaskImage(
//        bits: Int,
//        code: UInt64,
//        quietCellsEachSide: Int,
//        guardPattern: [UInt8]
//    ) -> CIImage? {
//        let dataBits = max(1, bits)
//        let cellsTotal = quietCellsEachSide * 2 + guardPattern.count * 2 + dataBits
//        var row = [UInt8](repeating: 0, count: cellsTotal)
//
//        var x = 0
//        // quiet (ліва тиша)
//        x += quietCellsEachSide
//        // guard (ліворуч)
//        for v in guardPattern { row[x] = v > 0 ? 255 : 0; x += 1 }
//        // дані MSB → LSB
//        for i in 0..<dataBits {
//            let bit = (code >> UInt64(dataBits - 1 - i)) & 1
//            row[x] = bit == 1 ? 255 : 0
//            x += 1
//        }
//        // guard (праворуч)
//        for v in guardPattern { row[x] = v > 0 ? 255 : 0; x += 1 }
//        // quiet (права тиша)
//        // залишок заповнений нулями вже є
//        guard
//            let provider = CGDataProvider(data: Data(row) as CFData),
//            let cg = CGImage(
//                width: cellsTotal, height: 1,
//                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cellsTotal,
//                space: CGColorSpaceCreateDeviceGray(),
//                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
//                provider: provider, decode: nil,
//                shouldInterpolate: false, intent: .defaultIntent
//            )
//        else { return nil }
//        return CIImage(cgImage: cg)
//    }
//
//
//    private let sharedCIContext = CIContext(options: nil)
//
//    func decodeFrameNumberString(
//        from output: CIImage,
//        bits: Int = 32,
//        quiet: Int = 4,
//        guardPattern: [Int] = [1, 0, 1, 0, 1, 0],
//        bandHeight: CGFloat = 30,
//        isTop: Bool = false,
//        threshold: CGFloat = 0.5,
//        context: CIContext
//    ) -> String? {
//        let extent = output.extent
//        guard extent.width > 1, extent.height > 1 else { return nil }
//
//        // 1) Прямокутник смуги (знизу або зверху)
//        let bandH = min(bandHeight, extent.height)
//        let bandRect: CGRect = isTop
//            ? .init(x: extent.minX, y: extent.maxY - bandH, width: extent.width, height: bandH)
//            : .init(x: extent.minX, y: extent.minY,          width: extent.width, height: bandH)
//
//        // 2) Загальна кількість клітинок
//        let cellsTotal = quiet * 2 + guardPattern.count * 2 + bits
//        guard cellsTotal > 0 else { return nil }
//
//        // Невеликі відступи від меж клітин і по висоті, щоб уникати країв/шуму
//        let cellW = bandRect.width / CGFloat(cellsTotal)
//        let marginX = max(0.0, cellW * 0.15)
//        let marginY = max(0.0, bandRect.height * 0.30)
//
//        // 3) Допоміжна: середня яскравість прямокутника
//        func averageLuma(_ rect: CGRect) -> CGFloat {
//            guard let filter = CIFilter(name: "CIAreaAverage") else { return 1.0 }
//            filter.setValue(output, forKey: kCIInputImageKey)
//            filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
//            guard let onePixel = filter.outputImage else { return 1.0 }
//
//            var rgba = [UInt8](repeating: 0, count: 4)
//            context.render(
//                onePixel,
//                toBitmap: &rgba,
//                rowBytes: 4,
//                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
//                format: .RGBA8,
//                colorSpace: CGColorSpaceCreateDeviceRGB()
//            )
//            let r = CGFloat(rgba[0]) / 255.0
//            let g = CGFloat(rgba[1]) / 255.0
//            let b = CGFloat(rgba[2]) / 255.0
//            return 0.2126 * r + 0.7152 * g + 0.0722 * b
//        }
//
//        // 4) Зняти луми по центру комірок
//        var lumas: [CGFloat] = []
//        lumas.reserveCapacity(cellsTotal)
//        for i in 0..<cellsTotal {
//            let x0 = bandRect.minX + CGFloat(i) * cellW + marginX
//            let x1 = bandRect.minX + CGFloat(i + 1) * cellW - marginX
//            let y0 = bandRect.minY + marginY
//            let y1 = bandRect.maxY - marginY
//            let sampleRect = CGRect(
//                x: max(x0, bandRect.minX),
//                y: max(y0, bandRect.minY),
//                width: max(1.0, x1 - x0),
//                height: max(1.0, y1 - y0)
//            )
//            lumas.append(averageLuma(sampleRect))
//        }
//
//        // 4.1) Динамічний поріг (якщо threshold < 0): ітеративна схема Ridler–Calvard
//        let thr: CGFloat = {
//            if threshold >= 0 { return threshold }
//            guard let minL = lumas.min(), let maxL = lumas.max() else { return 0.5 }
//            var t = (minL + maxL) * 0.5
//            for _ in 0..<6 {
//                var sum0: CGFloat = 0, cnt0: CGFloat = 0
//                var sum1: CGFloat = 0, cnt1: CGFloat = 0
//                for v in lumas {
//                    if v < t { sum1 += v; cnt1 += 1 } else { sum0 += v; cnt0 += 1 }
//                }
//                if cnt0 == 0 || cnt1 == 0 { break }
//                let m0 = sum0 / max(cnt0, 1)
//                let m1 = sum1 / max(cnt1, 1)
//                let nt = (m0 + m1) * 0.5
//                if abs(nt - t) < 1e-3 { t = nt; break }
//                t = nt
//            }
//            return t
//        }()
//
//        // 4.2) Перетворити у біти: білий=0, чорний=1
//        var cells: [Int] = []
//        cells.reserveCapacity(cellsTotal)
//        for v in lumas {
//            cells.append(v < thr ? 1 : 0)
//        }
//
//        // 5) Виділити дані (MSB→LSB)
//        let g = guardPattern.count
//        let dataStart = quiet + g
//        let dataEnd = dataStart + bits
//        guard dataEnd <= cells.count else { return nil }
//        let dataBits = cells[dataStart..<dataEnd]
//
//        // 6) Зібрати число з бітів (MSB ліворуч)
//        var value: UInt64 = 0
//        for b in dataBits {
//            value = (value << 1) | (b == 1 ? 1 : 0)
//        }
//        return String(value)
//    }
//}


struct StripConfig {
    let bits: Int                // кількість біт даних
    let quiet: Int               // тихі клітини зліва/справа
    let guardPattern: [Int]      // старт/стоп патерн, напр. [1,0,1,0,1,0]
    let bandHeight: CGFloat      // висота смуги у пікселях
    let isTop: Bool              // смуга зверху (true) чи знизу (false)
    let threshold: CGFloat       // поріг яскравості для 0/1 (0..1), напр. 0.5
}

extension CIImage: @unchecked @retroactive Sendable {}
extension CIContext: @unchecked @retroactive Sendable {}
extension CVPixelBuffer: @unchecked @retroactive Sendable {}

actor FrameSnapshotWorker {

    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let lastFrame: LastFramesStore

    init(
        colorSpace: CGColorSpace,
        context: CIContext,
        lastFrame: LastFramesStore
    ) {
        self.colorSpace = colorSpace
        self.context = context
        self.lastFrame = lastFrame
    }

    func enqueueJPEG(pixelBuffer: CVPixelBuffer, codeIndex: UInt64) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        enqueueJPEG(image: image, codeIndex: codeIndex)
    }

    func enqueueJPEG(image: CIImage, codeIndex: UInt64) {
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0
        ]
//        print("W_W_W \(image.colorSpace?.name)")
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: image.colorSpace ?? colorSpace,
            options: opts
        )
        else { return }
        let sizeKB = Double(data.count) / 1024.0
        logger.info("Frame number: \(codeIndex) - size: \(sizeKB)KB")

        Task {
            await lastFrame.storeFrame(data, codeIndex: codeIndex)
        }
    }

    func enqueueRawBuffer(image: CIImage, codeIndex: UInt64) {

        let extent = image.extent.integral
        let width  = Int(extent.width)
        let height = Int(extent.height)
        let bytesPerPixel = 4                       // BGRA 8-bit
        var raw = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        context.render(
            image,
            toBitmap: &raw,
            rowBytes: width * bytesPerPixel,
            bounds: extent,
            format: .BGRA8,
            colorSpace: colorSpace
        )

        let rawData = Data(raw)
//        let rawKB = Double(rawData.count) / 1024.0//
//        logger.info("RAW Frame number: \(codeIndex) - size: \(rawKB)KB")

        Task {
            await lastFrame.storeFrame(rawData, codeIndex: codeIndex)
        }
    }

    func enqueueHEIC(image: CIImage, codeIndex: UInt64) {

        let options: [CIImageRepresentationOption: Any] = [:
//                .init(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9
        ]
        guard let heicData = context.heifRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: options
        )
        else { return }

//        let sizeKB = Double(heicData.count) / 1024.0
//        logger.info("Frame number: \(codeIndex) - size: \(sizeKB)KB")

        Task {
            await lastFrame.storeFrame(heicData, codeIndex: codeIndex)
        }
    }
}

enum StreamSettingsConstants {

    static let frameBitStripeModel = FrameBitStripeModel()
    static let bandHeightPx: CGFloat = 30
    static let bits: Int = 32

    static let framesPerCode: Int = 3
    static let lowBatteryFramesPerCode: Int = 10
    static let criticalBatteryFramesPerCode: Int =  15
    static let fairThermalFramesPerCode: Int =  15
    static let checkIntervalInFrames: Int =  30 * 60 // every 1 minute

    static let fps: Int = 30
    static let imageCompressionQuality = 1.0
    static let sessionPreset: AVCaptureSession.Preset = .hd4K3840x2160
    static let streamScreenSize = CGSize(width: 720, height: 1280)
    static let originScreenSize: CGSize = CGSize(width: 2160, height: 3840)

    static let defaultVideoBitRate: Int = 1200 * 1000
    static let maximumVideoBitRate: Int = 2500 * 1000
    static let minimumVideoBitRate: Int = 20 * 1000
    static let increaseStepAdaptiveBitRate: Int = 200 * 1000 // mamimumVideoBitrate / 10
    static let increaseThresholdAdaptiveBitRate: Int = 15
    static let stableForLearnUpAdaptiveBitRate: Int = 60
    static let learnDownFactorAdaptiveBitRate: Double = 0.9
    static let learnUpFactorAdaptiveBitRate: Double = 1.05
    static let isDataRateLimitsEnable: Bool = false

    static let defaultAudioBitRate: Int = 64 * 1000

    static let directoryPhotoshootsName = "PhotoshootFrames"
    static let prefixFrameNameFromat = "code_"
    static let suffixFrameNameFromat = ".jpg"
    static var fullFrameNameFromat: String {
        // "code_%llu.jpg"
        return "\(prefixFrameNameFromat)%llu\(suffixFrameNameFromat)"
    }
    static var savedFramesPerSecond: Int {
        return fps / framesPerCode
    }
    static var lastFramesStoreCapacity: Int {
        savedFramesPerSecond * 90 + 100
    }
}

struct FrameBitStripeModel: Sendable {

    let bandHeightPx: Int = 30
    let bits: Int = 32
    let quietCellsEachSide: Int = 0 // 4
    let guardPattern: [UInt8] = [] // [1, 0, 1, 0, 1, 0]
    let stripColorSpace = CGColorSpaceCreateDeviceRGB()
    let whiteRGB: SIMD3<Float> = .init(1, 1, 1)
    let blackRGB: SIMD3<Float> = .init(0, 0, 0)
    let decodeThreshold: CGFloat = 0.5
}

struct DecodeFrameIdentifierUseCase {

    private let bitStripeModel: FrameBitStripeModel
    private let streamScreenSize: CGSize
    private let context: CIContext

    init(
        bitStripeModel: FrameBitStripeModel = StreamSettingsConstants.frameBitStripeModel,
        streamScreenSize: CGSize = StreamSettingsConstants.originScreenSize,
        context: CIContext = CIContext(options: [.cacheIntermediates: false])
    ) {
        self.bitStripeModel = bitStripeModel
        self.streamScreenSize = streamScreenSize
        self.context = context
    }

    func execute(
        _ ciImage: CIImage
    ) -> String? {
        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let scale = extent.height / streamScreenSize.height

        // 1) Прямокутник смуги (знизу або зверху)
        let originBandHeight = CGFloat(bitStripeModel.bandHeightPx)
        let scaledHeight = floor(originBandHeight * scale)
        let bandH = min(scaledHeight, extent.height) //min(bandHeight, extent.height)
        let bandRect = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: bandH)

        // 2) Загальна кількість клітинок
        let cellsTotal = bitStripeModel.quietCellsEachSide * 2 + bitStripeModel.guardPattern.count * 2 + bitStripeModel.bits
        guard cellsTotal > 0 else { return nil }

        // Невеликі відступи від меж клітин і по висоті, щоб уникати країв/шуму
        let cellW = bandRect.width / CGFloat(cellsTotal)
        let marginX = max(0.0, cellW * 0.15)
        let marginY = max(0.0, bandRect.height * 0.30)

        // 3) Допоміжна: середня яскравість прямокутника
        func averageLuma(_ rect: CGRect) -> CGFloat {
            guard let filter = CIFilter(name: "CIAreaAverage") else { return 1.0 }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
            guard let onePixel = filter.outputImage else { return 1.0 }

            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(
                onePixel,
                toBitmap: &rgba,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            let r = CGFloat(rgba[0]) / 255.0
            let g = CGFloat(rgba[1]) / 255.0
            let b = CGFloat(rgba[2]) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        // 4) Зняти луми по центру комірок
        var lumas: [CGFloat] = []
        lumas.reserveCapacity(cellsTotal)
        for i in 0..<cellsTotal {
            let x0 = bandRect.minX + CGFloat(i) * cellW + marginX
            let x1 = bandRect.minX + CGFloat(i + 1) * cellW - marginX
            let y0 = bandRect.minY + marginY
            let y1 = bandRect.maxY - marginY
            let sampleRect = CGRect(
                x: max(x0, bandRect.minX),
                y: max(y0, bandRect.minY),
                width: max(1.0, x1 - x0),
                height: max(1.0, y1 - y0)
            )
            lumas.append(averageLuma(sampleRect))
        }

        // 4.1) Динамічний поріг (якщо threshold < 0): ітеративна схема Ridler–Calvard
        let thr: CGFloat = {
            if bitStripeModel.decodeThreshold >= 0 { return bitStripeModel.decodeThreshold }
            guard let minL = lumas.min(), let maxL = lumas.max() else { return 0.5 }
            var t = (minL + maxL) * 0.5
            for _ in 0..<6 {
                var sum0: CGFloat = 0, cnt0: CGFloat = 0
                var sum1: CGFloat = 0, cnt1: CGFloat = 0
                for v in lumas {
                    if v < t { sum1 += v; cnt1 += 1 } else { sum0 += v; cnt0 += 1 }
                }
                if cnt0 == 0 || cnt1 == 0 { break }
                let m0 = sum0 / max(cnt0, 1)
                let m1 = sum1 / max(cnt1, 1)
                let nt = (m0 + m1) * 0.5
                if abs(nt - t) < 1e-3 { t = nt; break }
                t = nt
            }
            return t
        }()

        // 4.2) Перетворити у біти: білий=0, чорний=1
        var cells: [Int] = []
        cells.reserveCapacity(cellsTotal)
        for v in lumas {
            cells.append(v < thr ? 1 : 0)
        }

        // 5) Виділити дані (MSB→LSB)
        let g = bitStripeModel.guardPattern.count
        let dataStart = bitStripeModel.quietCellsEachSide + g
        let dataEnd = dataStart + bitStripeModel.bits
        guard dataEnd <= cells.count else { return nil }
        let dataBits = cells[dataStart..<dataEnd]

        // 6) Зібрати число з бітів (MSB ліворуч)
        var value: UInt64 = 0
        for b in dataBits {
            value = (value << 1) | (b == 1 ? 1 : 0)
        }

        print("W_W_W code: \(value)")
        return String(value)
    }
}
