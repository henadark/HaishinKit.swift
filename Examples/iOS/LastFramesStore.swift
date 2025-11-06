import Foundation
import CoreImage


// Stores recent frames (without the bit strip) on disk for a retention window (e.g., last 90s).
// Lightweight, async, best‑effort: drops frames silently if IO is busy.
actor LastFramesStore {

    typealias FrameIdentifier = UInt64

    private let maxCapacity: Int

    private let fileWriterActor: FileWriterActor

    struct Item: Codable {
        let url: URL
        let code: FrameIdentifier
    }
    private var index: [Item] = []
    private var byCode: [FrameIdentifier: Item] = [:]
    private var storedFrameIds: Set<FrameIdentifier> = []

    private var lastFrameData: Data?

    init(
        maxCapacity: Int,
        fileWriterActor: FileWriterActor
    ) {
        self.maxCapacity = maxCapacity
        self.fileWriterActor = fileWriterActor
        self.index.reserveCapacity(maxCapacity)
        self.byCode.reserveCapacity(maxCapacity)
        self.storedFrameIds.reserveCapacity(maxCapacity)
    }

    func storeFrame(_ data: Data, codeIndex: FrameIdentifier) {

        Task { [weak self] in
            guard let self else { return }
            if let url = await self.fileWriterActor.write(data, codeIndex: codeIndex) {
                await self.append(url: url, code: codeIndex, data: data)
            }
        }
    }

    private func append(url: URL, code: FrameIdentifier, data: Data) {
        guard byCode[code] == nil else {
            assertionFailure("Duplicate frame with index: \(code)")
            return
        }
        let item = Item(url: url, code: code)
        index.append(item)
        byCode[code] = item
        lastFrameData = data
        prune()
    }

    private func prune() {
        // Update timestamp in index by appending new and letting prune remove old
        if let removedItem = removeFirstTemporaryItemIfNeeded() {
            let writer = fileWriterActor
            Task {
                await writer.remove(at: removedItem.url)
                logger.info("🙂 Remove temporary file: \(removedItem.code)")
            }
        }
    }

    private func addTemporaryItem(_ item: Item) {
        index.append(item)
        byCode[item.code] = item
    }

    private func removeFirstTemporaryItemIfNeeded() -> Item? {
        guard index.count > maxCapacity else { return nil }
        let item = index.removeFirst()
        byCode[item.code] = nil
        return item
    }

    private func removeTemporaryItem(by id: FrameIdentifier) {

        if let i = index.firstIndex(where: { $0.code == id }) {
            index.remove(at: i)
        }
        byCode[id] = nil
    }

    func checkIfFrameIsExistAndUpdate(by id: FrameIdentifier) -> Bool {
        if byCode[id] != nil {
            removeTemporaryItem(by: id)
            storedFrameIds.insert(id)
            return true
        }
        return storedFrameIds.contains(id)
    }

    func filterStoredFrames(by ids: [FrameIdentifier]) -> [FrameIdentifier] {
        let existedIds: [FrameIdentifier] = ids.filter { checkIfFrameIsExistAndUpdate(by: $0) }
        return existedIds
    }

    func getLastFrame() -> (id: FrameIdentifier, data: Data)? {
        guard
            let lastItem = index.last,
            checkIfFrameIsExistAndUpdate(by: lastItem.code),
            let data = lastFrameData
        else { return nil }

        return (id: lastItem.code, data: data)
    }
}

actor FileWriterActor {

    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager, baseURL: URL) {
        self.fileManager = fileManager
        self.baseURL = baseURL
    }

//    func write(_ data: Data, to url: URL) throws {
//        try data.write(to: url, options: .atomic)
//    }

    func write(_ data: Data, codeIndex: UInt64) -> URL? {
        let file = baseURL.appendingPathComponent(String(format: "code_%llu.jpg", codeIndex))

        #if DEBUG
        if fileManager.fileExists(atPath: file.path) {
            assertionFailure("File already exists: \(file.path)")
        }
        #endif

        do {
            try data.write(to: file, options: .atomic)
            logger.info("🗳️ Store file on disk: \(codeIndex)")
            return file
        } catch {
            logger.info("🗳️ FAILED Store file on disk: \(codeIndex)")
            return nil
        }
    }

    func remove(at url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }
}


struct SaveStreamFramesBuilder {

    private let maxCapacity = StreamSettingsConstants.savedFramesPerSecond * 90 + 100
    private let directoryName = "LastFrames"

    func buildFileWriterActor(streamId: String) throws -> FileWriterActor {

        let fileManager = FileManager.default

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, // .documentDirectory - visible files for user
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        var streamDir = appSupport
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: streamId, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: streamDir, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try streamDir.setResourceValues(resourceValues)

//        let urls = try fileManager.contentsOfDirectory(
//            at: streamDir,
//            includingPropertiesForKeys: nil,
//            options: [.skipsHiddenFiles]
//        )
//        for url in urls {
//            let data = try Data(contentsOf: url)
//            let sizeKB = Double(data.count) / 1024.0
//
//            print("W_W_W \(url.lastPathComponent) - \(sizeKB)KB")
//        }

        return FileWriterActor(fileManager: fileManager, baseURL: streamDir)
    }

    func buildLastFramesStore(streamId: String) throws -> LastFramesStore {
        let fileWriterActor = try buildFileWriterActor(streamId: streamId)
        return LastFramesStore(maxCapacity: maxCapacity, fileWriterActor: fileWriterActor)
    }

    func buildFrameSnapshotWorker(streamId: String = "1") throws -> FrameSnapshotWorker {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() //CGColorSpace(name: CGColorSpace.displayP3)
        let context = CIContext(
            options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false,
                .workingColorSpace: NSNull()
            ]
        )
        let lastFrame = try buildLastFramesStore(streamId: streamId)

        return FrameSnapshotWorker(
            colorSpace: colorSpace,
            context: context,
            lastFrame: lastFrame
        )
    }

    func buildFrameSnapshotWorker2(streamId: String = "1") throws -> FrameSnapshotWorker2 {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() //CGColorSpace(name: CGColorSpace.displayP3)
        let context = CIContext(
            options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false,
                .workingColorSpace: NSNull()
            ]
        )
        let lastFrame = try buildLastFramesStore(streamId: streamId)

        return FrameSnapshotWorker2(
            colorSpace: colorSpace,
            context: context,
            lastFrame: lastFrame
        )
    }
}
