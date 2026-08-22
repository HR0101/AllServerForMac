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
}
