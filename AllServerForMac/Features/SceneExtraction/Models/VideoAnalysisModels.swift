// AllServerForMac/Features/SceneExtraction/Models/VideoAnalysisModels.swift

import Foundation

nonisolated struct VideoDocument: Identifiable, Codable, Sendable {
  let id: UUID
  let url: URL
  let duration: Double
  let nominalFrameRate: Double
  let resolutionWidth: Int
  let resolutionHeight: Int
  let hasAudioTrack: Bool
  let hasVideoTrack: Bool
  let audioSampleRate: Double?
  let timeScale: Int32

  init(
    id: UUID = UUID(),
    url: URL,
    duration: Double,
    nominalFrameRate: Double,
    resolutionWidth: Int,
    resolutionHeight: Int,
    hasAudioTrack: Bool,
    hasVideoTrack: Bool,
    audioSampleRate: Double?,
    timeScale: Int32
  ) {
    self.id = id
    self.url = url
    self.duration = duration
    self.nominalFrameRate = nominalFrameRate
    self.resolutionWidth = resolutionWidth
    self.resolutionHeight = resolutionHeight
    self.hasAudioTrack = hasAudioTrack
    self.hasVideoTrack = hasVideoTrack
    self.audioSampleRate = audioSampleRate
    self.timeScale = timeScale
  }
}

nonisolated struct AudioFeaturePoint: Identifiable, Codable, Sendable {
  let id: UUID
  let time: Double
  let rms: Double
  let bandEnergy100To1500: Double
  let delta: Double
  let decay: Double
  let zScore: Double

  init(
    id: UUID = UUID(),
    time: Double,
    rms: Double,
    bandEnergy100To1500: Double,
    delta: Double,
    decay: Double,
    zScore: Double
  ) {
    self.id = id
    self.time = time
    self.rms = rms
    self.bandEnergy100To1500 = bandEnergy100To1500
    self.delta = delta
    self.decay = decay
    self.zScore = zScore
  }
}

nonisolated struct VisualFeaturePoint: Identifiable, Codable, Sendable {
  let id: UUID
  let time: Double
  let frameDiff: Double
  let meanLuminance: Double
  let luminanceDiff: Double
  let edgeDiff: Double
  let motionSpike: Double
  let motionDrop: Double
  let zScore: Double

  init(
    id: UUID = UUID(),
    time: Double,
    frameDiff: Double,
    meanLuminance: Double,
    luminanceDiff: Double,
    edgeDiff: Double,
    motionSpike: Double,
    motionDrop: Double,
    zScore: Double
  ) {
    self.id = id
    self.time = time
    self.frameDiff = frameDiff
    self.meanLuminance = meanLuminance
    self.luminanceDiff = luminanceDiff
    self.edgeDiff = edgeDiff
    self.motionSpike = motionSpike
    self.motionDrop = motionDrop
    self.zScore = zScore
  }
}

nonisolated struct TransitionFeaturePoint: Identifiable, Codable, Sendable {
  let id: UUID
  let time: Double
  let freezeScore: Double
  let dissolveScore: Double
  let fadeScore: Double
  let editScore: Double

  init(
    id: UUID = UUID(),
    time: Double,
    freezeScore: Double,
    dissolveScore: Double,
    fadeScore: Double,
    editScore: Double
  ) {
    self.id = id
    self.time = time
    self.freezeScore = freezeScore
    self.dissolveScore = dissolveScore
    self.fadeScore = fadeScore
    self.editScore = editScore
  }
}

nonisolated struct FeatureVector: Identifiable, Codable, Sendable {
  let id: UUID
  let time: Double
  let audioBandEnergy: Double
  let audioRise: Double
  let audioDecay: Double
  let visualMotion: Double
  let visualSpike: Double
  let visualDrop: Double
  let freezeScore: Double
  let dissolveScore: Double
  let fadeScore: Double
  let editScore: Double
  var combinedScore: Double

  init(
    id: UUID = UUID(),
    time: Double,
    audioBandEnergy: Double,
    audioRise: Double,
    audioDecay: Double,
    visualMotion: Double,
    visualSpike: Double,
    visualDrop: Double,
    freezeScore: Double,
    dissolveScore: Double,
    fadeScore: Double,
    editScore: Double,
    combinedScore: Double = 0
  ) {
    self.id = id
    self.time = time
    self.audioBandEnergy = audioBandEnergy
    self.audioRise = audioRise
    self.audioDecay = audioDecay
    self.visualMotion = visualMotion
    self.visualSpike = visualSpike
    self.visualDrop = visualDrop
    self.freezeScore = freezeScore
    self.dissolveScore = dissolveScore
    self.fadeScore = fadeScore
    self.editScore = editScore
    self.combinedScore = combinedScore
  }
}

nonisolated enum CandidateLabel: String, Codable, CaseIterable, Sendable {
  case accepted
  case rejected
  case uncertain

  var displayName: String {
    switch self {
    case .accepted:
      return "採用"
    case .rejected:
      return "却下"
    case .uncertain:
      return "保留"
    }
  }
}

nonisolated struct CandidateSegment: Identifiable, Codable, Sendable {
  let id: UUID
  var startTime: Double
  var endTime: Double
  var peakTime: Double
  var score: Double
  var audioScore: Double
  var visualScore: Double
  var transitionScore: Double
  var reason: [String]
  var userLabel: CandidateLabel?

  init(
    id: UUID = UUID(),
    startTime: Double,
    endTime: Double,
    peakTime: Double,
    score: Double,
    audioScore: Double,
    visualScore: Double,
    transitionScore: Double,
    reason: [String],
    userLabel: CandidateLabel? = nil
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.peakTime = peakTime
    self.score = score
    self.audioScore = audioScore
    self.visualScore = visualScore
    self.transitionScore = transitionScore
    self.reason = reason
    self.userLabel = userLabel
  }
}

nonisolated enum AnalysisStage: String, Codable, Sendable {
  case preparing
  case extractingAudio
  case extractingVideo
  case detectingTransitions
  case mergingFeatures
  case detectingCandidates
  case completed

  var displayName: String {
    switch self {
    case .preparing:
      return "準備中"
    case .extractingAudio:
      return "音声解析中"
    case .extractingVideo:
      return "映像解析中"
    case .detectingTransitions:
      return "遷移解析中"
    case .mergingFeatures:
      return "特徴量統合中"
    case .detectingCandidates:
      return "候補抽出中"
    case .completed:
      return "完了"
    }
  }
}

nonisolated struct AnalysisProgress: Codable, Sendable {
  let stage: AnalysisStage
  let fractionCompleted: Double
}

nonisolated struct VideoAnalysisResult: Codable, Sendable {
  let document: VideoDocument
  let settings: AnalysisSettings
  let audioFeatures: [AudioFeaturePoint]
  let visualFeatures: [VisualFeaturePoint]
  let transitionFeatures: [TransitionFeaturePoint]
  let mergedFeatures: [FeatureVector]
  let candidates: [CandidateSegment]
  let createdAt: Date
}

nonisolated struct ExportMetadata: Codable, Sendable {
  let sourceURL: String
  let sourceFileName: String
  let startTime: Double
  let endTime: Double
  let peakTime: Double
  let duration: Double
  let fps: Double
  let frameCount: Int
  let score: Double
  let audioScore: Double
  let visualScore: Double
  let transitionScore: Double
  let reason: [String]
  let createdAt: Date
}

nonisolated struct ClipExportResult: Sendable {
  let videoURL: URL
  let metadataURL: URL?
  let metadata: ExportMetadata
}
