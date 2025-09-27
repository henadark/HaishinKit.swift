import CoreImage
import CoreGraphics
import UIKit
import HaishinKit
import AVFoundation

// MARK: - Stream settings code (suffix)
public enum StreamSettings: String {
    case photoModeEnabled  = "01"
    case photoModeDisabled = "02"

    public var code: String { rawValue }
}

final class BitStripEffect: VideoEffect {
    // MARK: - Параметри
    var bandHeightPx: CGFloat = StreamSettingsConstants.bandHeightPx
    var bits: Int = StreamSettingsConstants.bits
    var framesPerCode: Int = StreamSettingsConstants.framesPerCode { didSet { framesPerCode = max(1, framesPerCode) } }
    var drawAtTop: Bool = false
    var whiteRGB: SIMD3<Float> = .init(1, 1, 1)
    var blackRGB: SIMD3<Float> = .init(0, 0, 0)
    // Додаткові службові пікселі: тихі зони і guard-патерн для кращої стабільності/детекції
    var quietCellsEachSide: Int = 0//4
    var guardPattern: [UInt8] = []//[1, 0, 1, 0, 1, 0]

    // MARK: - Photo mode flag (affects 2-char suffix code)
    public var isPhotoModeEnabled: Bool = false { didSet { needsMaskRebuild = true } }
    public func codeForMakePhotoOpportunity() -> String {
        isPhotoModeEnabled ? StreamSettings.photoModeEnabled.code : StreamSettings.photoModeDisabled.code
    }

    // MARK: - Стан
    private var frameCount = 0
    private var codeIndex: UInt64 = 0
    private var needsMaskRebuild = true
    private var cachedMask: CIImage?

    private lazy var kernelUnder: CIKernel? = Self.loadKernel(named: "bandMaskUnder")
    private lazy var kernelOverlay: CIKernel? = Self.loadKernel(named: "bandMaskOverlay")


    private let snapshotWorker: FrameSnapshotWorker? = try? SaveStreamFramesBuilder().buildFrameSnapshotWorker()

    func execute(_ image: CIImage) -> CIImage {
        let usingUnder = (kernelUnder != nil)
        guard let kernel = usingUnder ? kernelUnder : kernelOverlay else { return image }

        var fullFrameCode: UInt64 = 0

        // Інкрементуємо код раз на N кадрів
        if frameCount == 0 {
            codeIndex &+= 1
            needsMaskRebuild = true

//            snapshotWorker.enqueueJPEG(image: image, codeIndex: codeIndex)
            let decimalString = "\(codeIndex)\(codeForMakePhotoOpportunity())"
            fullFrameCode = UInt64(decimalString) ?? 0
            let index = fullFrameCode
            let worker = snapshotWorker
            Task {
                await worker?.enqueueJPEG(image: image, codeIndex: index)
            }

            // Зберегти кадр без смуги рівно раз на код, уникаючи передавання CIImage між виконавцями:
//            let opts: [CIImageRepresentationOption: Any] = [
//                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7
//            ]
//            
//            if let jpeg = snapshotContext.jpegRepresentation(of: image, colorSpace: snapshotColorSpace, options: opts) {
//                let current = codeIndex
//                Task {
//                    await LastFramesStore.shared.storeJPEG(jpeg, codeIndex: current)
//                }
//            }
        }
        frameCount &+= 1
        if frameCount >= framesPerCode { frameCount = 0 }

        if needsMaskRebuild || cachedMask == nil {
            // Формуємо десятковий рядок: frameNumber + 2-символьний суфікс режиму

            cachedMask = Self.buildMaskImage(
                bits: bits,
                code: fullFrameCode,
                quietCellsEachSide: quietCellsEachSide,
                guardPattern: guardPattern
            )
            needsMaskRebuild = false
        }
        guard let mask = cachedMask else { return image }

        let src = image.extent
        let bandH = max(1, bandHeightPx)
        // Позиція смуги: для overlay — всередині вихідного кадру;
        // для under — параметр не використовується ядром, але передаємо для узгодженості.
        let bandY: CGFloat = {
            if usingUnder {
                return drawAtTop ? (src.minY + src.height) : src.minY
            } else {
                // overlay: смуга в межах src
                return drawAtTop ? (src.minY + src.height - bandH) : src.minY
            }
        }()

        // Розміри для ядра
        let widthPx = Float(src.width)
        let heightPx = Float(src.height)
        let bandYF = Float(bandY)
        let bandHF = Float(bandH)

        // Вихідний extent
        let outExtent: CGRect = usingUnder
        ? CGRect(x: src.minX, y: src.minY, width: src.width, height: src.height + bandH) // "під" відео
        : src // overlay поверх

        // ROI: під різні ядра різна стратегія
        let roi: CIKernelROICallback = { index, rect in
            if index == 0 {
                if usingUnder {
                    // Ядро семплить src при y - bandH, тому ROI зміщуємо вниз і обрізаємо
                    let shifted = rect.offsetBy(dx: 0, dy: -bandH)
                    return shifted.intersection(src)
                } else {
                    // overlay: семплим в межах rect
                    return rect
                }
            } else {
                return mask.extent
            }
        }

        // Кількість клітинок (quiet | guard | data | guard | quiet)
        let cellsTotal = quietCellsEachSide * 2 + guardPattern.count * 2 + bits

        let args: [Any] = [
            image,
            mask,
            widthPx, heightPx,
            bandYF, bandHF,
            Float(cellsTotal),
            whiteRGB.x, whiteRGB.y, whiteRGB.z,
            blackRGB.x, blackRGB.y, blackRGB.z,
            Float(outExtent.minX), Float(outExtent.width)
        ]
        //print("Code index: \(codeIndex)")
        logger.info("Code index: \(codeIndex)")
let outputImage = kernel.apply(extent: outExtent, roiCallback: roi, arguments: args) ?? image
//        if let frameStr = decodeFrameNumberString(from: outputImage,
//                                                  bits: bits,
//                                                  quiet: quietCellsEachSide,
//                                                  guardPattern: guardPattern.map(Int.init),
//                                                  bandHeight: bandHeightPx,
//                                                  isTop: drawAtTop,
//                                                  threshold: -1.0, //  щоб завжди використовувався динамічний поріг.
//                                                  context: sharedCIContext
//        ) {
////            print("Frame \(frameStr)")
//            logger.info("Frame \(frameStr)")
//        }


        return outputImage
    }

    // Локальний контекст для JPEG-снапшоту (безпечний для меж акторів)
    private lazy var snapshotContext = CIContext(options: [.cacheIntermediates: false])
    private let snapshotColorSpace = CGColorSpaceCreateDeviceRGB()
    // MARK: - Kernel loading
    private static func loadKernel(named fn: String) -> CIKernel? {
        // Підвантаження з твого бандла (не SPM)
        let candidates: [Bundle] = [
            Bundle(for: BitStripEffect.self),
            Bundle.main
        ]
        for b in candidates {
            if let url = b.url(forResource: "default", withExtension: "metallib"),
               let data = try? Data(contentsOf: url),
               let k = try? CIKernel(functionName: fn, fromMetalLibraryData: data) {
                return k
            }
        }
        return nil
    }

    // MARK: - Маска 1×cells (quiet | guard | data(MSB→LSB) | guard | quiet)
    private static func buildMaskImage(
        bits: Int,
        code: UInt64,
        quietCellsEachSide: Int,
        guardPattern: [UInt8]
    ) -> CIImage? {
        let dataBits = max(1, bits)
        let cellsTotal = quietCellsEachSide * 2 + guardPattern.count * 2 + dataBits
        var row = [UInt8](repeating: 0, count: cellsTotal)

        var x = 0
        // quiet (ліва тиша)
        x += quietCellsEachSide
        // guard (ліворуч)
        for v in guardPattern { row[x] = v > 0 ? 255 : 0; x += 1 }
        // дані MSB → LSB
        for i in 0..<dataBits {
            let bit = (code >> UInt64(dataBits - 1 - i)) & 1
            row[x] = bit == 1 ? 255 : 0
            x += 1
        }
        // guard (праворуч)
        for v in guardPattern { row[x] = v > 0 ? 255 : 0; x += 1 }
        // quiet (права тиша)
        // залишок заповнений нулями вже є
        guard
            let provider = CGDataProvider(data: Data(row) as CFData),
            let cg = CGImage(
                width: cellsTotal, height: 1,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cellsTotal,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
            )
        else { return nil }
        return CIImage(cgImage: cg)
    }


    private let sharedCIContext = CIContext(options: nil)

    func decodeFrameNumberString(
        from output: CIImage,
        bits: Int = 32,
        quiet: Int = 4,
        guardPattern: [Int] = [1, 0, 1, 0, 1, 0],
        bandHeight: CGFloat = 30,
        isTop: Bool = false,
        threshold: CGFloat = 0.5,
        context: CIContext
    ) -> String? {
        let extent = output.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        // 1) Прямокутник смуги (знизу або зверху)
        let bandH = min(bandHeight, extent.height)
        let bandRect: CGRect = isTop
            ? .init(x: extent.minX, y: extent.maxY - bandH, width: extent.width, height: bandH)
            : .init(x: extent.minX, y: extent.minY,          width: extent.width, height: bandH)

        // 2) Загальна кількість клітинок
        let cellsTotal = quiet * 2 + guardPattern.count * 2 + bits
        guard cellsTotal > 0 else { return nil }

        // Невеликі відступи від меж клітин і по висоті, щоб уникати країв/шуму
        let cellW = bandRect.width / CGFloat(cellsTotal)
        let marginX = max(0.0, cellW * 0.15)
        let marginY = max(0.0, bandRect.height * 0.30)

        // 3) Допоміжна: середня яскравість прямокутника
        func averageLuma(_ rect: CGRect) -> CGFloat {
            guard let filter = CIFilter(name: "CIAreaAverage") else { return 1.0 }
            filter.setValue(output, forKey: kCIInputImageKey)
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
            if threshold >= 0 { return threshold }
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
        let g = guardPattern.count
        let dataStart = quiet + g
        let dataEnd = dataStart + bits
        guard dataEnd <= cells.count else { return nil }
        let dataBits = cells[dataStart..<dataEnd]

        // 6) Зібрати число з бітів (MSB ліворуч)
        var value: UInt64 = 0
        for b in dataBits {
            value = (value << 1) | (b == 1 ? 1 : 0)
        }
        return String(value)
    }
}


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

    static let bandHeightPx: CGFloat = 30
    static let bits: Int = 32
    static let framesPerCode: Int = 3
    static let fps: Int = 30
    static var savedFramesPerSecond: Int {
        return fps / framesPerCode
    }
}
