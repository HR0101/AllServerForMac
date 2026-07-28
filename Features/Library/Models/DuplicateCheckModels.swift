import Foundation

struct DuplicateCheckState: Codable, Hashable {
    let checkedAt: Date
    let albumSignature: String
}

struct DuplicateCheckResult {
    let checkedCount: Int
    let duplicateCount: Int
    let missingFileCount: Int
    let failedHashCount: Int
}
