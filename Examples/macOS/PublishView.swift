import AVFoundation
import HaishinKit
import SwiftUI

enum FPS: String, CaseIterable, Identifiable {
    case fps15 = "15"
    case fps30 = "30"
    case fps60 = "60"

    var frameRate: Float64 {
        switch self {
        case .fps15:
            return 15
        case .fps30:
            return 30
        case .fps60:
            return 60
        }
    }

    var id: Self { self }
}

enum VideoEffectItem: String, CaseIterable, Identifiable, Sendable {
    case none
    case monochrome

    var id: Self { self }

    func makeVideoEffect() -> VideoEffect? {
        switch self {
        case .none:
            return nil
        case .monochrome:
            return MonochromeEffect()
        }
    }
}

struct PublishView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var preference: PreferenceViewModel
    @StateObject private var model = PublishViewModel()

    var body: some View {
        ZStack {
            VStack {
                MTHKViewRepresentable(previewSource: model)
            }
            VStack(alignment: .trailing) {
                Picker("FPS", selection: $model.currentFPS) {
                    ForEach(FPS.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .onChange(of: model.currentFPS) { tag in
                    model.setFrameRate(tag.frameRate)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding()
                Spacer()
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    switch model.readyState {
                    case .connecting:
                        Spacer()
                    case .open:
                        Button(action: {
                            model.stopPublishing()
                        }, label: {
                            Image(systemName: "stop.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    case .closing:
                        Spacer()
                    case .closed:
                        Button(action: {
                            model.startPublishing(preference)
                        }, label: {
                            Image(systemName: "record.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    }
                }
            }
        }
        .onAppear {
            model.startRunning(preference)
        }
        .onDisappear {
            model.stopRunning()
        }.alert(isPresented: $model.isShowError) {
            Alert(
                title: Text("Error"),
                message: Text(model.error?.localizedDescription ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

#Preview {
    PublishView()
}
