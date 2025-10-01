import Foundation
import HaishinKit

public struct HTTPSessionFactory: SessionFactory {
    public let supportedProtocols: Set<String> = ["http", "https"]

    public init() {
    }

    public func make(_ uri: URL, method: SessionMethod) -> any Session {
        return HTTPSession(uri: uri, method: method)
    }
}
