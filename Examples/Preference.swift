import Foundation

struct Preference: Sendable {
    // Temp
    static nonisolated(unsafe) var `default` = Preference()

    // var uri = "http://192.168.1.14:1985/rtc/v1/whip/?app=live&stream=livestream"
    var uri = "rtmp://localhost/live"
    var streamName = "live"

    func makeURL() -> URL? {
        if uri.contains("rtmp://") {
            return URL(string: uri + "/" + streamName)
        }
        return URL(string: uri)
    }
}
