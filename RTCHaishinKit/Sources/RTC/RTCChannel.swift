import Foundation
import libdatachannel

class RTCChannel {
    let id: Int32

    var isOpen = false
    var isClosed = false

    init(id: Int32) {
        self.id = id
        rtcSetUserPointer(id, Unmanaged.passUnretained(self).toOpaque())
        rtcSetOpenCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<RTCChannel>.fromOpaque(pointer).takeUnretainedValue().isOpen = true
        }
        rtcSetClosedCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<RTCChannel>.fromOpaque(pointer).takeUnretainedValue().isClosed = true
        }
        rtcSetMessageCallback(id) { _, bytes, size, pointer in
            guard let bytes, let pointer else { return }
            let data = Data(bytes: bytes, count: Int(size))
            Unmanaged<RTCChannel>.fromOpaque(pointer).takeUnretainedValue().didReceiveMessage(data)
        }
        rtcSetErrorCallback(id) { _, error, pointer in
            guard let error, let pointer else { return }
            Unmanaged<RTCChannel>.fromOpaque(pointer).takeUnretainedValue().errorOccurred(String(cString: error))
        }
    }

    func send(_ message: Data) throws {
        try RTCError.check(message.withUnsafeBytes { pointer in
            return rtcSendMessage(id, pointer.bindMemory(to: CChar.self).baseAddress, Int32(message.count))
        })
    }

    func close() {
        _ = try? RTCError.check(rtcClose(id))
    }

    func errorOccurred(_ error: String) {
    }

    func didReceiveMessage(_ message: Data) {
    }
}
