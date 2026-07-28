import Foundation

struct DuplicateCheckState: Codable, Hashable, Sendable {
    let checkedAt: Date
    let albumSignature: String
}

struct DuplicateCheckResult: Sendable {
    let checkedCount: Int
    let duplicateCount: Int
    let missingFileCount: Int
    let failedHashCount: Int
}
