import MediaServerKit
import XCTest

final class RangeHeaderTests: XCTestCase {
  func testFullRangeFromStart() {
    let range = RangeHeader.parse("bytes=0-", totalSize: 1000)
    XCTAssertEqual(range?.0, 0)
    XCTAssertEqual(range?.1, 999)
  }

  func testExplicitRange() {
    let range = RangeHeader.parse("bytes=100-199", totalSize: 1000)
    XCTAssertEqual(range?.0, 100)
    XCTAssertEqual(range?.1, 199)
  }

  func testEndClampedToTotalSize() {
    let range = RangeHeader.parse("bytes=900-5000", totalSize: 1000)
    XCTAssertEqual(range?.0, 900)
    XCTAssertEqual(range?.1, 999)
  }

  func testRejectsNonBytesUnit() {
    XCTAssertNil(RangeHeader.parse("items=0-1", totalSize: 1000))
  }

  func testRejectsZeroTotalSize() {
    XCTAssertNil(RangeHeader.parse("bytes=0-", totalSize: 0))
  }

  func testRejectsInvertedRange() {
    XCTAssertNil(RangeHeader.parse("bytes=500-100", totalSize: 1000))
  }
}
