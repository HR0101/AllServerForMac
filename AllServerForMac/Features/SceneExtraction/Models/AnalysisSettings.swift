// AllServerForMac/Features/SceneExtraction/Models/AnalysisSettings.swift

import Foundation

nonisolated enum AnalysisSettingsError: LocalizedError {
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .invalidValue(let message):
      return "設定値が不正です．\(message)"
    }
  }
}

nonisolated struct AnalysisSettings: Codable, Equatable, Sendable {
  static let defaultClipDuration = 10.0
  static let defaultPeakLeadTime = 4.0
  static let defaultTargetFramesPerSecond = 24
  static let defaultTargetFrameCount = 241
  static let defaultAudioWeight = 0.4
  static let defaultVisualWeight = 0.4
  static let defaultTransitionWeight = 0.2
  static let defaultContextWeight = 0.15
  static let defaultCandidateThreshold = 0.62
  static let defaultMinimumCandidateDistance = 8.0
  static let defaultFreezeThreshold = 0.012
  static let defaultAnalysisFramesPerSecond = 8.0
  static let defaultAudioWindowDuration = 0.1

  var clipDuration = Self.defaultClipDuration
  var peakLeadTime = Self.defaultPeakLeadTime
  var targetFramesPerSecond = Self.defaultTargetFramesPerSecond
  var targetFrameCount = Self.defaultTargetFrameCount
  var audioWeight = Self.defaultAudioWeight
  var visualWeight = Self.defaultVisualWeight
  var transitionWeight = Self.defaultTransitionWeight
  var contextWeight = Self.defaultContextWeight
  var candidateThreshold = Self.defaultCandidateThreshold
  var minimumCandidateDistance = Self.defaultMinimumCandidateDistance
  var freezeThreshold = Self.defaultFreezeThreshold
  var analysisFramesPerSecond = Self.defaultAnalysisFramesPerSecond
  var audioWindowDuration = Self.defaultAudioWindowDuration
  var includesAudio = true
  var writesSidecarJSON = true
  var writesDatasetCSV = true
  var usesHEVC = false

  var peakTrailTime: Double {
    max(0, clipDuration - peakLeadTime)
  }

  var outputDuration: Double {
    Double(targetFrameCount) / Double(max(1, targetFramesPerSecond))
  }

  func validateForAnalysis() throws {
    guard clipDuration > 0 else {
      throw AnalysisSettingsError.invalidValue("候補区間は0秒より長くしてください．")
    }
    guard peakLeadTime >= 0, peakLeadTime <= clipDuration else {
      throw AnalysisSettingsError.invalidValue("ピークまでの時間は候補区間内にしてください．")
    }
    guard analysisFramesPerSecond > 0, audioWindowDuration > 0 else {
      throw AnalysisSettingsError.invalidValue("解析fpsと音声窓は0より大きくしてください．")
    }
    guard minimumCandidateDistance >= 0, freezeThreshold >= 0 else {
      throw AnalysisSettingsError.invalidValue("候補間隔とfreezeしきい値は0以上にしてください．")
    }
    guard (0...1).contains(candidateThreshold) else {
      throw AnalysisSettingsError.invalidValue("候補しきい値は0〜1にしてください．")
    }
    guard audioWeight >= 0,
          visualWeight >= 0,
          transitionWeight >= 0,
          contextWeight >= 0 else {
      throw AnalysisSettingsError.invalidValue("重みは0以上にしてください．")
    }
  }

  func validateForExport() throws {
    try validateForAnalysis()
    guard targetFramesPerSecond > 0 else {
      throw AnalysisSettingsError.invalidValue("出力fpsは1以上にしてください．")
    }
    guard targetFrameCount > 0 else {
      throw AnalysisSettingsError.invalidValue("出力フレーム数は1以上にしてください．")
    }
  }
}
