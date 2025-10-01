import Foundation

struct RTCICECandidate: Sendable {
    let candidate: String
    let mid: String
}

extension RTCICECandidate {
    init(candidate: UnsafePointer<CChar>?, mid: UnsafePointer<CChar>?) {
        if let candidate {
            self.candidate = String(cString: candidate)
        } else {
            self.candidate = ""
        }
        if let mid {
            self.mid = String(cString: mid)
        } else {
            self.mid = ""
        }
    }
}
