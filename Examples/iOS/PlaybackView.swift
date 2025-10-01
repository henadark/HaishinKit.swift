import HaishinKit
import SwiftUI

struct PlaybackView: View {
    @StateObject private var model = PlaybackViewModel()

    var body: some View {
        ZStack {
            VStack {
                PiPHKViewRepresentable(previewSource: model)
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
                            Task {
                                await model.stop()
                            }
                        }, label: {
                            Image(systemName: "stop.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    case .closed:
                        Button(action: {
                            Task {
                                await model.start()
                            }
                        }, label: {
                            Image(systemName: "play.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    case .closing:
                        Spacer()
                    }
                }
            }
            if model.readyState == .connecting {
                VStack {
                    ProgressView()
                }
            }
        }.task {
            await model.makeSession()
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
    PlaybackView()
}
