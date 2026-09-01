// AllServerForMac/Features/SceneExtraction/Services/RuleBasedClimaxClassifier.swift

import Foundation

nonisolated struct RuleBasedClimaxClassifier: ClimaxClassifier {
  let settings: AnalysisSettings

  func score(features: FeatureVector) -> Double {
    let audioPattern = (
      0.45 * features.audioBandEnergy
        + 0.20 * features.audioRise
        + 0.35 * features.audioDecay
    )
    let visualPattern = (
      0.35 * features.visualMotion
        + 0.35 * features.visualSpike
        + 0.30 * features.visualDrop
    )
    let transitionPattern = max(
      features.freezeScore,
      0.8 * features.dissolveScore,
      0.8 * features.fadeScore,
      features.editScore
    )
    let contextPattern = max(
      features.audioDecay * features.visualDrop,
      features.visualSpike * features.freezeScore
    )
    let totalWeight = max(
      0.000_001,
      settings.audioWeight
        + settings.visualWeight
        + settings.transitionWeight
        + settings.contextWeight
    )
    let weightedScore = (
      settings.audioWeight * audioPattern
        + settings.visualWeight * visualPattern
        + settings.transitionWeight * transitionPattern
        + settings.contextWeight * contextPattern
    ) / totalWeight
    return min(max(0, weightedScore), 1)
  }
}
