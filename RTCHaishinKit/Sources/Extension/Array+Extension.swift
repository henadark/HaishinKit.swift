import Foundation

extension Array where Element == String {
    func withCStrings<R>(_ body: ([UnsafePointer<CChar>]) -> R) -> R {
        var cStringPtrs: [UnsafePointer<CChar>] = []
        cStringPtrs.reserveCapacity(count)
        func loop(_ i: Int, _ current: [UnsafePointer<CChar>], _ body: ([UnsafePointer<CChar>]) -> R) -> R {
            if i == count {
                return body(current)
            }
            return self[i].withCString { cstr in
                var next = current
                next.append(cstr)
                return loop(i + 1, next, body)
            }
        }
        return loop(0, [], body)
    }
}
