import AppKit
import Foundation

public protocol SharingService {
    func share(urls: [URL]) throws
}

public enum SharingServiceError: LocalizedError {
    case noItems
    case airDropUnavailable

    public var errorDescription: String? {
        switch self {
        case .noItems:
            return "没有可分享的文件"
        case .airDropUnavailable:
            return "当前环境无法使用 AirDrop"
        }
    }
}

public struct AirDropSharingService: SharingService {
    public init() {}

    public func share(urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw SharingServiceError.noItems
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw SharingServiceError.airDropUnavailable
        }

        service.perform(withItems: urls)
    }
}
