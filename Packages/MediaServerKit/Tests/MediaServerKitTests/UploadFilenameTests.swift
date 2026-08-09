import MediaServerKit
import XCTest

final class UploadFilenameTests: XCTestCase {
  func testTraversalStripped() {
    XCTAssertEqual(UploadFilename.sanitize("../../movie.mp4"), "movie.mp4")
  }

  func testAbsolutePathStripped() {
    XCTAssertEqual(UploadFilename.sanitize("/abs/path/clip.MOV"), "clip.MOV")
  }

  func testRejectsNonMediaExtension() {
    XCTAssertNil(UploadFilename.sanitize("../../etc/passwd"))
    XCTAssertNil(UploadFilename.sanitize("malware.exe"))
  }

  func testRejectsHiddenDotAndEmpty() {
    XCTAssertNil(UploadFilename.sanitize(".hidden.mp4"))
    XCTAssertNil(UploadFilename.sanitize(""))
    XCTAssertNil(UploadFilename.sanitize("."))
    XCTAssertNil(UploadFilename.sanitize(".."))
  }

  func testTrimsSurroundingWhitespace() {
    XCTAssertEqual(UploadFilename.sanitize("  spaced.png  "), "spaced.png")
  }

  func testBackslashTraversalRejected() {
    XCTAssertNil(UploadFilename.sanitize("evil.mp4\\..\\x"))
  }

  func testPlainMediaAccepted() {
    XCTAssertEqual(UploadFilename.sanitize("photo.jpg"), "photo.jpg")
    XCTAssertEqual(UploadFilename.sanitize("clip.mp4"), "clip.mp4")
  }
}
