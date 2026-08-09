import MediaServerKit
import XCTest

final class PINSecurityTests: XCTestCase {
  func testEqualPinsMatch() {
    XCTAssertTrue(PINSecurity.constantTimeEquals("123456", "123456"))
  }

  func testDifferentPinsReject() {
    XCTAssertFalse(PINSecurity.constantTimeEquals("123456", "123457"))
  }

  func testDifferentLengthRejects() {
    XCTAssertFalse(PINSecurity.constantTimeEquals("123456", "12345"))
  }

  func testEmptyEqualsEmpty() {
    XCTAssertTrue(PINSecurity.constantTimeEquals("", ""))
  }

  func testNoLockoutUnderThreshold() {
    XCTAssertNil(PINSecurity.lockoutDelay(failCount: 4))
  }

  func testLockoutEscalation() {
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 5), 30)
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 6), 60)
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 7), 120)
  }

  func testLockoutCapsAtOneHour() {
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 100), 3600)
  }
}
