import HaishinKit
@preconcurrency import Logboard
import RTCHaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import SwiftUI

nonisolated let logger = LBLogger.with("com.haishinkit.HaishinApp")

@main
struct HaishinApp: App {
    @State private var preference = PreferenceViewModel()

    var body: some Scene {
        WindowGroup {
            PublishView()
                .environmentObject(preference)
//            PhotoView()
        }
    }

    init() {
        Task {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            await SessionBuilderFactory.shared.register(SRTSessionFactory())
            await SessionBuilderFactory.shared.register(HTTPSessionFactory())

            await RTCLogger.shared.setLevel(.debug)
            await SRTLogger.shared.setLevel(.debug)
        }
        LBLogger(kHaishinKitIdentifier).level = .debug
        LBLogger(kRTCHaishinKitIdentifier).level = .debug
        LBLogger(kRTMPHaishinKitIdentifier).level = .debug
        LBLogger(kSRTHaishinKitIdentifier).level = .debug
    }
}


import Photos

struct PhotoView: View {
    @ObservedObject var vm: PhotoViewModel = PhotoViewModel()
    var body: some View {
        VStack {
            HStack {
                Text("HELLO")

                Button("SAVE", action: vm.onSaveButtonTapped)
            }

            if let img = vm.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            }
        }
        .onAppear(perform: vm.onAppear)
    }
}

final class PhotoViewModel: ObservableObject {

    let fileManager = FileManager.default
    @Published var image: UIImage?

    func onAppear() {
        do {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory, // .documentDirectory - visible files for user
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            let streamDir = appSupport
                .appending(path: "LastFrames", directoryHint: .isDirectory)
                .appending(path: "1", directoryHint: .isDirectory)

                // REMOVE ALL FILES
//            do {
//                try fileManager.removeItem(at: streamDir)
//                print("Папку успішно видалено: \(streamDir.path)")
//            } catch {
//                print("Помилка під час видалення папки: \(error)")
//            }

            var nameOfFiles = try FileManager.default.contentsOfDirectory(atPath: streamDir.path)
            nameOfFiles = nameOfFiles.filter{$0.localizedCaseInsensitiveContains("code_")}
            var nums = nameOfFiles.compactMap {
                let decimalDigits = CharacterSet.decimalDigits
                let filteredString = $0.components(separatedBy: decimalDigits.inverted).joined()
                return Int(filteredString)
            }
//            nameOfFiles = nameOfFiles.sorted()
            nums = nums.sorted()
            if let num = nums.last {
                let path = streamDir.appendingPathComponent("code_\(num).jpg")
                let data = try Data(contentsOf: path.standardizedFileURL)
                image = UIImage(data: data)
            }


//            let file = streamDir.appendingPathComponent(String(format: "code_%llu.jpg", 20302))
//            let data = try Data(contentsOf: file.standardizedFileURL)
//            image = UIImage(data: data)
        } catch {
            print(error)
        }
    }

    func onSaveButtonTapped() {
        if let img = image {

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    print("Немає дозволу на збереження в Фото")
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                }, completionHandler: { success, error in
                    if success {
                        print("Збережено в Фото")
                    } else {
                        print("Помилка збереження: \(error?.localizedDescription ?? "невідома")")
                    }
                })
            }
        }
    }

}
