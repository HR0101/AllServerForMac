// AllServerForMac/Features/SceneExtraction/Services/VideoAnalysisPipeline.swift

import Foundation

nonisolated struct VideoAnalysisPipeline: Sendable {
  private let audioAnalyzer = AudioAnalyzer()
  private let visualAnalyzer = VisualAnalyzer()
  private let transitionAnalyzer = TransitionAnalyzer()
  private let featureMerger = FeatureMerger()
  private let candidateDetector = CandidateDetector()

  func analyze(
    document: VideoDocument,
    settings: AnalysisSettings,
    classifier customClassifier: (any ClimaxClassifier)? = nil,
    progress: @escaping @Sendable (AnalysisProgress) async -> Void
  ) async throws -> VideoAnalysisResult {
    try settings.validateForAnalysis()
    await progress(AnalysisProgress(stage: .preparing, fractionCompleted: 0.02))
    let audioAnalyzer = self.audioAnalyzer
    let visualAnalyzer = self.visualAnalyzer

    await progress(AnalysisProgress(stage: .extractingAudio, fractionCompleted: 0.08))
    async let audioFeatures = Task.detached(priority: .userInitiated) {
      try await audioAnalyzer.analyze(url: document.url, settings: settings)
    }.value

    await progress(AnalysisProgress(stage: .extractingVideo, fractionCompleted: 0.12))
    async let visualFeatures = Task.detached(priority: .userInitiated) {
      try await visualAnalyzer.analyze(url: document.url, settings: settings)
    }.value

    let (audio, visual) = try await (audioFeatures, visualFeatures)
    try Task.checkCancellation()

    await progress(AnalysisProgress(stage: .detectingTransitions, fractionCompleted: 0.72))
    let transitionAnalyzer = self.transitionAnalyzer
    let transitions = try await Task.detached(priority: .userInitiated) {
      try transitionAnalyzer.analyze(visualPoints: visual, settings: settings)
    }.value

    await progress(AnalysisProgress(stage: .mergingFeatures, fractionCompleted: 0.82))
    let featureMerger = self.featureMerger
    var merged = try await Task.detached(priority: .userInitiated) {
      try featureMerger.merge(
        audioPoints: audio,
        visualPoints: visual,
        transitionPoints: transitions
      )
    }.value

    let classifier = customClassifier ?? RuleBasedClimaxClassifier(settings: settings)
    merged = try await Task.detached(priority: .userInitiated) {
      var scoredFeatures = merged
      for index in scoredFeatures.indices {
        try Task.checkCancellation()
        scoredFeatures[index].combinedScore = classifier.score(features: scoredFeatures[index])
      }
      return scoredFeatures
    }.value

    await progress(AnalysisProgress(stage: .detectingCandidates, fractionCompleted: 0.92))
    let candidateDetector = self.candidateDetector
    let candidates = try await Task.detached(priority: .userInitiated) {
      try candidateDetector.detect(
        features: merged,
        duration: document.duration,
        settings: settings
      )
    }.value

    await progress(AnalysisProgress(stage: .completed, fractionCompleted: 1))
    return VideoAnalysisResult(
      document: document,
      settings: settings,
      audioFeatures: audio,
      visualFeatures: visual,
      transitionFeatures: transitions,
      mergedFeatures: merged,
      candidates: candidates,
      createdAt: Date()
    )
  }
}
