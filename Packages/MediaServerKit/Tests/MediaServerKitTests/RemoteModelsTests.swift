import MediaServerKit
import XCTest

final class RemoteModelsTests: XCTestCase {
  func testAlbumRoundTrip() throws {
    let album = RemoteAlbumInfo(id: "abc", name: "Trip", videoCount: 3, type: "video")
    let data = try JSONEncoder().encode(album)
    let decoded = try JSONDecoder().decode(RemoteAlbumInfo.self, from: data)
    XCTAssertEqual(album, decoded)
  }

  func testAlbumDecodesMissingType() throws {
    let json = Data(#"{"id":"x","name":"N","videoCount":0}"#.utf8)
    let decoded = try JSONDecoder().decode(RemoteAlbumInfo.self, from: json)
    XCTAssertNil(decoded.type)
  }

  /// サーバーは .iso8601 でエンコードし，クライアントは .iso8601 でデコードする取り決め．
  func testVideoISO8601Contract() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let video = RemoteVideoInfo(
      id: "1",
      filename: "a.mp4",
      duration: 12.5,
      importDate: Date(timeIntervalSince1970: 1_700_000_000),
      creationDate: nil,
      mediaType: "video"
    )
    let data = try encoder.encode(video)
    let decoded = try decoder.decode(RemoteVideoInfo.self, from: data)
    XCTAssertEqual(video, decoded)
    XCTAssertFalse(decoded.isPhoto)
  }

  func testIsPhoto() {
    let photo = RemoteVideoInfo(
      id: "1",
      filename: "a.heic",
      duration: 0,
      importDate: Date(),
      creationDate: nil,
      mediaType: "photo"
    )
    let video = RemoteVideoInfo(
      id: "2",
      filename: "b.mp4",
      duration: 1,
      importDate: Date(),
      creationDate: nil,
      mediaType: "video"
    )
    XCTAssertTrue(photo.isPhoto)
    XCTAssertFalse(video.isPhoto)
  }

  func testVideoDecodesMissingOptionalFields() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let json = Data(
      #"{"id":"1","filename":"a.mp4","duration":3.0,"importDate":"2024-01-01T00:00:00Z"}"#.utf8
    )
    let decoded = try decoder.decode(RemoteVideoInfo.self, from: json)
    XCTAssertNil(decoded.creationDate)
    XCTAssertNil(decoded.mediaType)
    XCTAssertFalse(decoded.isPhoto)
  }
}
