//
//  AllServerForMacTests.swift
//  AllServerForMacTests
//
//  Created by 原　颯登 on 2025/10/09.
//

import Foundation
import Testing
@testable import AllServerForMac

struct AllServerForMacTests {
  @Test @MainActor
  func reportsMissingMoviesDirectoryWithoutCreatingStorage() {
    var createdDirectories: [URL] = []
    let environment = LibraryStorageEnvironment(
      moviesDirectory: { nil },
      downloadsDirectory: { URL(fileURLWithPath: "/unused/downloads") },
      createDirectory: { createdDirectories.append($0) }
    )

    let viewModel = LibraryViewModel(storageEnvironment: environment)

    #expect(
      viewModel.storageInitializationError?.stage
        == .moviesDirectoryLookup
    )
    #expect(createdDirectories.isEmpty)
    #expect(!viewModel.isStorageReady)
    #expect(!viewModel.isLibraryLoaded)
  }

  @Test @MainActor
  func reportsMissingDownloadsDirectoryWithoutCreatingStorage() {
    var createdDirectories: [URL] = []
    let environment = LibraryStorageEnvironment(
      moviesDirectory: { URL(fileURLWithPath: "/unused/movies") },
      downloadsDirectory: { nil },
      createDirectory: { createdDirectories.append($0) }
    )

    let viewModel = LibraryViewModel(storageEnvironment: environment)

    #expect(
      viewModel.storageInitializationError?.stage
        == .downloadsDirectoryLookup
    )
    #expect(createdDirectories.isEmpty)
    #expect(!viewModel.isStorageReady)
    #expect(!viewModel.isLibraryLoaded)
  }

  @Test @MainActor
  func directoryCreationFailureDoesNotCreateEmptyLibrary() throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "AllServerForMacTests-\(UUID().uuidString)"
    )
    try fileManager.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let blockedAppRoot = temporaryRoot.appendingPathComponent(
      "MacVideoServerData"
    )
    try Data("not-a-directory".utf8).write(to: blockedAppRoot)

    let environment = LibraryStorageEnvironment(
      moviesDirectory: { temporaryRoot },
      downloadsDirectory: {
        temporaryRoot.appendingPathComponent("Downloads")
      },
      createDirectory: { url in
        try fileManager.createDirectory(
          at: url,
          withIntermediateDirectories: true
        )
      }
    )

    let viewModel = LibraryViewModel(storageEnvironment: environment)
    viewModel.saveData()

    #expect(
      viewModel.storageInitializationError?.stage == .directoryCreation
    )
    #expect(
      viewModel.storageInitializationError?.targetPath
        == blockedAppRoot.path
    )
    #expect(!viewModel.isStorageReady)
    #expect(!viewModel.isLibraryLoaded)
    #expect(
      !fileManager.fileExists(
        atPath: blockedAppRoot
          .appendingPathComponent("library.json")
          .path
      )
    )
  }

  @Test @MainActor
  func systemTrashKeepsFailedMediaInLibrary() throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "AllServerForMacTrashTests-\(UUID().uuidString)"
    )
    let moviesDirectory = temporaryRoot.appendingPathComponent("Movies")
    let downloadsDirectory = temporaryRoot.appendingPathComponent("Downloads")
    try fileManager.createDirectory(
      at: moviesDirectory,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: downloadsDirectory,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let movableURL = temporaryRoot.appendingPathComponent("movable.mp4")
    let blockedURL = temporaryRoot.appendingPathComponent("blocked.mp4")
    try Data("movable".utf8).write(to: movableURL)
    try Data("blocked".utf8).write(to: blockedURL)

    let environment = LibraryStorageEnvironment(
      moviesDirectory: { moviesDirectory },
      downloadsDirectory: { downloadsDirectory },
      createDirectory: { url in
        try fileManager.createDirectory(
          at: url,
          withIntermediateDirectories: true
        )
      },
      moveFileToSystemTrash: { url in
        if url == blockedURL {
          throw CocoaError(.fileWriteNoPermission)
        }
        try fileManager.removeItem(at: url)
      }
    )
    let viewModel = LibraryViewModel(storageEnvironment: environment)
    viewModel.libraryLoadTask?.cancel()

    let movableID = UUID()
    let blockedID = UUID()
    viewModel.videos = [
      VideoItem(
        id: movableID,
        originalFilename: movableURL.lastPathComponent,
        internalFilename: "",
        duration: 1,
        importDate: Date(),
        creationDate: nil,
        fileHash: "",
        externalFilePath: movableURL.path
      ),
      VideoItem(
        id: blockedID,
        originalFilename: blockedURL.lastPathComponent,
        internalFilename: "",
        duration: 1,
        importDate: Date(),
        creationDate: nil,
        fileHash: "",
        externalFilePath: blockedURL.path
      ),
    ]
    let albumID = UUID()
    viewModel.albums = [
      Album(
        id: albumID,
        name: "テスト",
        videoIDs: [movableID, blockedID],
        type: .video
      )
    ]

    let result = viewModel.moveMediaFilesToSystemTrash(
      videoIDs: [movableID, blockedID]
    )

    #expect(result.movedVideoIDs == [movableID])
    #expect(result.failures.map(\.videoID) == [blockedID])
    #expect(viewModel.videos.map(\.id) == [blockedID])
    #expect(viewModel.albums.first?.videoIDs == [blockedID])
    #expect(!fileManager.fileExists(atPath: movableURL.path))
    #expect(fileManager.fileExists(atPath: blockedURL.path))
    #expect(viewModel.mediaDeletionNotice != nil)
  }
}
