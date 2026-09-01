// AllServerForMac/Features/SceneExtraction/Services/FeatureMerger.swift

import Foundation

nonisolated struct FeatureMerger: Sendable {
  private let smoothingRadius = 2
  private let minimumStandardDeviation = 0.000_000_1

  func merge(
    audioPoints: [AudioFeaturePoint],
    visualPoints: [VisualFeaturePoint],
    transitionPoints: [TransitionFeaturePoint]
  ) throws -> [FeatureVector] {
    guard !visualPoints.isEmpty else { return [] }

    let audioTimes = audioPoints.map(\.time)
    let visualTimes = visualPoints.map(\.time)
    let transitionTimes = transitionPoints.map(\.time)
    let audioEnergy = normalize(audioPoints.map(\.bandEnergy100To1500))
    let audioRise = normalize(audioPoints.map { max(0, $0.delta) })
    let audioDecay = normalize(audioPoints.map(\.decay))
    let visualMotion = normalize(visualPoints.map(\.frameDiff))
    let visualSpike = normalize(visualPoints.map(\.motionSpike))
    let visualDrop = normalize(visualPoints.map(\.motionDrop))
    let freezeScores = transitionPoints.map(\.freezeScore)
    let dissolveScores = transitionPoints.map(\.dissolveScore)
    let fadeScores = transitionPoints.map(\.fadeScore)
    let editScores = transitionPoints.map(\.editScore)

    var merged: [FeatureVector] = []
    merged.reserveCapacity(visualPoints.count)

    for (index, time) in visualTimes.enumerated() {
      try Task.checkCancellation()
      merged.append(
        FeatureVector(
          time: time,
          audioBandEnergy: sample(times: audioTimes, values: audioEnergy, at: time),
          audioRise: sample(times: audioTimes, values: audioRise, at: time),
          audioDecay: sample(times: audioTimes, values: audioDecay, at: time),
          visualMotion: visualMotion[index],
          visualSpike: visualSpike[index],
          visualDrop: visualDrop[index],
          freezeScore: sample(
            times: transitionTimes,
            values: freezeScores,
            at: time
          ),
          dissolveScore: sample(
            times: transitionTimes,
            values: dissolveScores,
            at: time
          ),
          fadeScore: sample(
            times: transitionTimes,
            values: fadeScores,
            at: time
          ),
          editScore: sample(
            times: transitionTimes,
            values: editScores,
            at: time
          )
        )
      )
    }
    return merged
  }

  private func normalize(_ values: [Double]) -> [Double] {
    guard !values.isEmpty else { return [] }
    let smoothed = rollingMean(values, radius: smoothingRadius)
    let mean = smoothed.reduce(0, +) / Double(smoothed.count)
    let variance = smoothed.reduce(0) { partial, value in
      partial + pow(value - mean, 2)
    } / Double(smoothed.count)
    let standardDeviation = sqrt(variance)
    guard standardDeviation >= minimumStandardDeviation else {
      return [Double](repeating: 0, count: values.count)
    }

    return smoothed.map { value in
      let zScore = (value - mean) / standardDeviation
      return 1 / (1 + exp(-zScore))
    }
  }

  private func rollingMean(_ values: [Double], radius: Int) -> [Double] {
    values.indices.map { index in
      let lowerBound = max(0, index - radius)
      let upperBound = min(values.count, index + radius + 1)
      let window = values[lowerBound..<upperBound]
      return window.reduce(0, +) / Double(window.count)
    }
  }

  private func sample(times: [Double], values: [Double], at time: Double) -> Double {
    guard !times.isEmpty, times.count == values.count else { return 0 }
    guard times.count > 1 else { return values[0] }
    if time <= times[0] { return values[0] }
    if time >= times[times.count - 1] { return values[values.count - 1] }

    var lowerIndex = 0
    var upperIndex = times.count - 1
    while lowerIndex + 1 < upperIndex {
      let middleIndex = (lowerIndex + upperIndex) / 2
      if times[middleIndex] <= time {
        lowerIndex = middleIndex
      } else {
        upperIndex = middleIndex
      }
    }

    let lowerTime = times[lowerIndex]
    let upperTime = times[upperIndex]
    let interval = upperTime - lowerTime
    guard interval > 0 else { return values[lowerIndex] }
    let fraction = (time - lowerTime) / interval
    return values[lowerIndex] + (values[upperIndex] - values[lowerIndex]) * fraction
  }
}
