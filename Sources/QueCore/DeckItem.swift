// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation

public enum DeckItemType: String, Codable {
    case image
    case fileURL
}

public struct DeckItem: Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let type: DeckItemType
    public let fileURL: URL
    public let originalFileName: String?
    public let dataSize: Int
    /// The whole video a GIF was made from, so the GIF editor can pick another moment. nil for everything else.
    public let sourceVideoURL: URL?

    public init(id: UUID = UUID(), createdAt: Date = Date(), type: DeckItemType, fileURL: URL, originalFileName: String? = nil, dataSize: Int, sourceVideoURL: URL? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.fileURL = fileURL
        self.originalFileName = originalFileName
        self.dataSize = dataSize
        self.sourceVideoURL = sourceVideoURL
    }
}
