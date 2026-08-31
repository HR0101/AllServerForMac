// AllServerForMac/Features/SceneExtraction/Services/CandidateDetector.swift

import Foundation

nonisolated struct CandidateDetector: Sendable {
  private let localPeakRadius = 3
  private let reasonThreshold = 0.65

  func detect(
    features: [FeatureVector],
    duration: Double,
    settings: AnalysisSettings
  ) throws -> [CandidateSegment] {
    guard features.count >= 3, duration > 0 else { return [] }
    var peakFeatures: [FeatureVector] = []

    for index in features.indices {
      try Task.checkCancellation()
      let feature = features[index]
      guard feature.combinedScore >= settings.candidateThreshold else { continue }
      let lowerBound = max(0, index - localPeakRadius)
      let upperBound = min(features.count, index + localPeakRadius + 1)
      let localMaximum = features[lowerBound..<upperBound]
        .map(\.combinedScore)
        .max() ?? 0
      if feature.combinedScore >= localMaximum {
        peakFeatures.append(feature)
      }
    }

    var acceptedPeaks: [FeatureVector] = []
    for peak in peakFeatures.sorted(by: { $0.combinedScore > $1.combinedScore }) {
      let isFarEnough = acceptedPeaks.allSatisfy {
        abs($0.time - peak.time) >= settings.minimumCandidateDistance
      }
      if isFarEnough {
        acceptedPeaks.append(peak)
      }
    }

    return acceptedPeaks.map { feature in
      makeCandidate(feature: feature, duration: duration, settings: settings)
    }
    .sorted { $0.score > $1.score }
  }

  private func makeCandidate(
    feature: FeatureVector,
    duration: Double,
    settings: AnalysisSettings
  ) -> CandidateSegment {
    var startTime = max(0, feature.time - settings.peakLeadTime)
    var endTime = min(duration, startTime + settings.clipDuration)
    if endTime - startTime < settings.clipDuration, duration >= settings.clipDuration {
      startTime = max(0, duration - settings.clipDuration)
      endTime = duration
    }

    let audioScore = max(feature.audioBandEnergy, feature.audioRise, feature.audioDecay)
    let visualScore = max(feature.visualMotion, feature.visualSpike, feature.visualDrop)
    let transitionScore = max(
      feature.freezeScore,
      feature.dissolveScore,
      feature.fadeScore,
      feature.editScore
    )
    var reasons: [String] = []
    if audioScore >= reasonThreshold { reasons.append("音声ピーク・減衰") }
    if visualScore >= reasonThreshold { reasons.append("映像変化・停止") }
    if feature.freezeScore >= reasonThreshold { reasons.append("freeze") }
    if feature.dissolveScore >= reasonThreshold { reasons.append("dissolve") }
    if feature.fadeScore >= reasonThreshold { reasons.append("fade") }
    if feature.editScore >= reasonThreshold { reasons.append("編集遷移") }
    if reasons.isEmpty { reasons.append("合成スコア") }

    return CandidateSegment(
      startTime: startTime,
      endTime: endTime,
      peakTime: feature.time,
      score: feature.combinedScore,
      audioScore: audioScore,
      visualScore: visualScore,
      transitionScore: transitionScore,
      reason: reasons
    )
  }
}
