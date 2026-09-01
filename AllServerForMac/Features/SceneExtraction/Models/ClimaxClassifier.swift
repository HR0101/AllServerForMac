// AllServerForMac/Features/SceneExtraction/Models/ClimaxClassifier.swift

import Foundation

nonisolated protocol ClimaxClassifier: Sendable {
  func score(features: FeatureVector) -> Double
}
