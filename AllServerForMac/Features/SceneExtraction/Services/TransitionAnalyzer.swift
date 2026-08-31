// AllServerForMac/Features/SceneExtraction/Services/TransitionAnalyzer.swift

import Foundation

nonisolated struct TransitionAnalyzer: Sendable {
  private let freezeConfirmationDuration = 0.5
  private let transitionWindowDuration = 1.0
  private let minimumFadeLuminanceChange = 0.08
  private let dissolveReferenceDiff = 0.06
  private let editSpikeScale = 10.0

  func analyze(
    visualPoints: [VisualFeaturePoint],
    settings: AnalysisSettings
  ) throws -> [TransitionFeaturePoint] {
    guard !visualPoints.isEmpty else { return [] }
    let frameInterval = 1 / max(1, settings.analysisFramesPerSecond)
    let windowRadius = max(2, Int((transitionWindowDuration / frameInterval / 2).rounded()))
    var freezeDuration = 0.0
    var results: [TransitionFeaturePoint] = []
    results.reserveCapacity(visualPoints.count)

    for index in visualPoints.indices {
      try Task.checkCancellation()
      let point = visualPoints[index]
      if point.frameDiff <= settings.freezeThreshold {
        freezeDuration += frameInterval
      } else {
        freezeDuration = 0
      }

      let freezeScore = clamp(freezeDuration / freezeConfirmationDuration)
      let localPoints = window(around: index, radius: windowRadius, points: visualPoints)
      let dissolveScore = calculateDissolveScore(localPoints)
      let fadeScore = calculateFadeScore(localPoints)
      let editScore = calculateEditScore(at: index, points: visualPoints, settings: settings)

      results.append(
        TransitionFeaturePoint(
          time: point.time,
          freezeScore: freezeScore,
          dissolveScore: dissolveScore,
          fadeScore: fadeScore,
          editScore: editScore
        )
      )
    }
    return results
  }

  private func calculateDissolveScore(_ points: ArraySlice<VisualFeaturePoint>) -> Double {
    guard points.count >= 5 else { return 0 }
    let differences = points.map(\.frameDiff)
    let mean = differences.reduce(0, +) / Double(differences.count)
    guard mean > 0 else { return 0 }
    let variance = differences.reduce(0) { partial, value in
      partial + pow(value - mean, 2)
    } / Double(differences.count)
    let coefficientOfVariation = sqrt(variance) / mean
    let smoothness = clamp(1 - coefficientOfVariation)
    let activity = clamp(mean / dissolveReferenceDiff)

    // 単発ピークではなく，中程度の差分が滑らかに持続するほど高くします．
    return smoothness * activity
  }

  private func calculateFadeScore(_ points: ArraySlice<VisualFeaturePoint>) -> Double {
    guard points.count >= 5,
          let first = points.first,
          let last = points.last else { return 0 }
    let totalChange = abs(last.meanLuminance - first.meanLuminance)
    guard totalChange >= minimumFadeLuminanceChange else { return 0 }

    let luminances = points.map(\.meanLuminance)
    let expectedDirection = last.meanLuminance >= first.meanLuminance ? 1.0 : -1.0
    var matchingSteps = 0
    for index in 1..<luminances.count {
      let step = luminances[index] - luminances[index - 1]
      if step * expectedDirection >= 0 {
        matchingSteps += 1
      }
    }
    let monotonicity = Double(matchingSteps) / Double(max(1, luminances.count - 1))
    return clamp(totalChange / 0.35) * monotonicity
  }

  private func calculateEditScore(
    at index: Int,
    points: [VisualFeaturePoint],
    settings: AnalysisSettings
  ) -> Double {
    guard index > 0, index + 2 < points.count else { return 0 }
    let beforeStart = max(0, index - 3)
    let before = points[beforeStart..<index]
    let afterEnd = min(points.count, index + 4)
    let after = points[(index + 1)..<afterEnd]
    let beforeMean = before.map(\.frameDiff).reduce(0, +) / Double(max(1, before.count))
    let afterMean = after.map(\.frameDiff).reduce(0, +) / Double(max(1, after.count))
    let spike = clamp((points[index].frameDiff - beforeMean) * editSpikeScale)
    let quietAfter = clamp(1 - afterMean / max(settings.freezeThreshold * 3, 0.000_001))
    return spike * quietAfter
  }

  private func window(
    around index: Int,
    radius: Int,
    points: [VisualFeaturePoint]
  ) -> ArraySlice<VisualFeaturePoint> {
    let lowerBound = max(0, index - radius)
    let upperBound = min(points.count, index + radius + 1)
    return points[lowerBound..<upperBound]
  }

  private func clamp(_ value: Double) -> Double {
    min(max(0, value), 1)
  }
}
