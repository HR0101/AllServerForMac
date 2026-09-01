// AllServerForMac/Features/SceneExtraction/ViewModels/SceneExtractionViewModel.swift

import AVFoundation
import Combine
import Foundation

@MainActor
final class SceneExtractionViewModel: ObservableObject {
  @Published private(set) var videoDocument: VideoDocument?
  @Published private(set) var currentTime = 0.0
  @Published private(set) var isPlaying = false
  @Published private(set) var isLoadingVideo = false
  @Published var candidates: [CandidateSegment] = []
  @Published var features: [FeatureVector] = []
  @Published var selectedCandidateID: UUID?
  @Published var isGroundTruthModeEnabled = false
  @Published var settings = AnalysisSettings()
  @Published var errorMessage: String?
  @Published private(set) var analysisResult: VideoAnalysisResult?
  @Published private(set) var analysisProgress: AnalysisProgress?
  @Published private(set) var isAnalyzing = false
  @Published private(set) var outputDirectoryURL: URL?
  @Published private(set) var isExportingClip = false
  @Published private(set) var isExportingDataset = false
  @Published var lastOperationMessage: String?

  let player = AVPlayer()

  private let documentLoader: VideoDocumentLoader
  private let analysisPipeline: VideoAnalysisPipeline
  private let clipExporter: ClipExporter
  private let datasetManager: DatasetManager
  private var analysisTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var previewRange: ClosedRange<Double>?
  private var timeObserver: Any?
  private let observerInterval = CMTime(value: 1, timescale: 20)

  init(
    documentLoader: VideoDocumentLoader = VideoDocumentLoader(),
    analysisPipeline: VideoAnalysisPipeline = VideoAnalysisPipeline(),
    clipExporter: ClipExporter = ClipExporter(),
    datasetManager: DatasetManager = DatasetManager()
  ) {
    self.documentLoader = documentLoader
    self.analysisPipeline = analysisPipeline
    self.clipExporter = clipExporter
    self.datasetManager = datasetManager
    configureTimeObserver()
  }

  deinit {
    analysisTask?.cancel()
    exportTask?.cancel()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
  }

  var duration: Double {
    videoDocument?.duration ?? 0
  }

  var selectedCandidate: CandidateSegment? {
    guard let selectedCandidateID else { return nil }
    return candidates.first { $0.id == selectedCandidateID }
  }

  func loadVideo(from url: URL) async {
    cancelAnalysis()
    pause()
    isLoadingVideo = true
    errorMessage = nil

    do {
      let document = try await documentLoader.load(from: url)
      guard !Task.isCancelled else { return }
      player.replaceCurrentItem(with: AVPlayerItem(url: url))
      videoDocument = document
      currentTime = 0
      candidates = []
      features = []
      analysisResult = nil
      analysisProgress = nil
      selectedCandidateID = nil
      previewRange = nil
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoadingVideo = false
  }

  func startAnalysis() {
    guard let videoDocument, !isAnalyzing else { return }
    cancelAnalysis()
    isAnalyzing = true
    errorMessage = nil
    analysisProgress = AnalysisProgress(stage: .preparing, fractionCompleted: 0)
    let settings = self.settings
    let analysisPipeline = self.analysisPipeline

    analysisTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let progressTarget = self
      do {
        let result = try await analysisPipeline.analyze(
          document: videoDocument,
          settings: settings
        ) { progress in
          await progressTarget.updateAnalysisProgress(progress)
        }
        try Task.checkCancellation()
        self.analysisResult = result
        self.features = result.mergedFeatures
        self.candidates = result.candidates
        self.selectedCandidateID = result.candidates.first?.id
      } catch is CancellationError {
        self.analysisProgress = nil
      } catch {
        self.errorMessage = "解析に失敗しました．\(error.localizedDescription)"
      }
      self.isAnalyzing = false
      self.analysisTask = nil
    }
  }

  func cancelAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    isAnalyzing = false
    analysisProgress = nil
  }

  func togglePlayback() {
    isPlaying ? pause() : play()
  }

  func play() {
    guard player.currentItem != nil else { return }
    player.play()
    isPlaying = true
  }

  func pause() {
    player.pause()
    isPlaying = false
  }

  func seek(to seconds: Double) {
    previewRange = nil
    seekPreservingPreview(to: seconds)
  }

  private func seekPreservingPreview(to seconds: Double) {
    guard duration > 0 else { return }
    let clampedSeconds = min(max(0, seconds), duration)
    let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    currentTime = clampedSeconds
  }

  func seek(by seconds: Double) {
    seek(to: currentTime + seconds)
  }

  func stepFrame(by count: Int) {
    guard count != 0, let currentItem = player.currentItem else { return }
    previewRange = nil
    pause()
    currentItem.step(byCount: count)
    currentTime = max(0, currentItem.currentTime().seconds)
  }

  func selectCandidate(_ candidate: CandidateSegment) {
    selectedCandidateID = candidate.id
    seek(to: candidate.peakTime)
  }

  func previewCandidate(_ candidate: CandidateSegment) {
    guard candidate.endTime > candidate.startTime else { return }
    selectedCandidateID = candidate.id
    previewRange = candidate.startTime...candidate.endTime
    seekPreservingPreview(to: candidate.startTime)
    play()
  }

  func setLabel(_ label: CandidateLabel, for candidateID: UUID) {
    guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
    candidates[index].userLabel = label
  }

  /// ラベルを保存し，スコア順で次の未判定候補を自動プレビューします．
  func reviewCandidate(_ label: CandidateLabel, candidateID: UUID) {
    setLabel(label, for: candidateID)
    let orderedCandidates = candidates.sorted { $0.score > $1.score }
    guard let currentIndex = orderedCandidates.firstIndex(where: { $0.id == candidateID }) else {
      return
    }

    let followingCandidates = orderedCandidates.dropFirst(currentIndex + 1)
    let precedingCandidates = orderedCandidates.prefix(currentIndex)
    let nextCandidate = followingCandidates.first { $0.userLabel == nil }
      ?? precedingCandidates.first { $0.userLabel == nil }

    if let nextCandidate {
      previewCandidate(nextCandidate)
    } else {
      selectedCandidateID = candidateID
    }
  }

  func setOutputDirectory(_ url: URL) {
    outputDirectoryURL = url
  }

  func updateCandidateStart(_ startTime: Double, candidateID: UUID) {
    guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
    candidates[index].startTime = min(
      max(0, startTime),
      candidates[index].endTime - 0.1
    )
  }

  func updateCandidateEnd(_ endTime: Double, candidateID: UUID) {
    guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
    candidates[index].endTime = max(
      candidates[index].startTime + 0.1,
      min(duration, endTime)
    )
  }

  func exportClip(_ candidate: CandidateSegment) {
    guard let videoDocument else {
      errorMessage = "書き出す動画が選択されていません．"
      return
    }
    guard let outputDirectoryURL else {
      errorMessage = "ComfyUIの出力先フォルダを選択してください．"
      return
    }
    guard !isExportingClip, !isExportingDataset else { return }
    isExportingClip = true
    lastOperationMessage = nil
    let clipExporter = self.clipExporter
    let settings = self.settings

    exportTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await clipExporter.export(
          document: videoDocument,
          candidate: candidate,
          settings: settings,
          outputDirectory: outputDirectoryURL
        )
        self.lastOperationMessage = "クリップを書き出しました．\n\(result.videoURL.path)"
      } catch is CancellationError {
        self.lastOperationMessage = "クリップ書き出しをキャンセルしました．"
      } catch {
        self.errorMessage = "クリップ書き出しに失敗しました．\(error.localizedDescription)"
      }
      self.isExportingClip = false
      self.exportTask = nil
    }
  }

  func cancelClipExport() {
    exportTask?.cancel()
  }

  func exportDataset() {
    guard let videoDocument else {
      errorMessage = "保存する動画が選択されていません．"
      return
    }
    guard let outputDirectoryURL else {
      errorMessage = "データセットの出力先フォルダを選択してください．"
      return
    }
    guard !isExportingDataset, !isExportingClip else { return }
    isExportingDataset = true
    lastOperationMessage = nil
    let datasetManager = self.datasetManager
    let settings = self.settings
    let analysisResult = self.analysisResult
    let candidates = self.candidates

    exportTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await datasetManager.export(
          document: videoDocument,
          settings: settings,
          analysisResult: analysisResult,
          candidates: candidates,
          outputDirectory: outputDirectoryURL,
          includesCSV: settings.writesDatasetCSV
        )
        self.lastOperationMessage = "解析データを保存しました．\n\(result.jsonURL.path)"
      } catch is CancellationError {
        self.lastOperationMessage = "データ保存をキャンセルしました．"
      } catch {
        self.errorMessage = "解析データの保存に失敗しました．\(error.localizedDescription)"
      }
      self.isExportingDataset = false
      self.exportTask = nil
    }
  }

  func addGroundTruthAtCurrentTime() {
    guard isGroundTruthModeEnabled, duration > 0 else { return }
    let peakTime = min(max(0, currentTime), duration)
    let startTime = max(0, peakTime - settings.peakLeadTime)
    let endTime = min(duration, startTime + settings.clipDuration)
    let groundTruth = CandidateSegment(
      startTime: startTime,
      endTime: endTime,
      peakTime: peakTime,
      score: 1,
      audioScore: 0,
      visualScore: 0,
      transitionScore: 0,
      reason: ["手動GT"],
      userLabel: .accepted
    )
    candidates.append(groundTruth)
    candidates.sort { $0.peakTime < $1.peakTime }
    selectedCandidateID = groundTruth.id
  }

  func clearError() {
    errorMessage = nil
  }

  private func updateAnalysisProgress(_ progress: AnalysisProgress) {
    analysisProgress = progress
  }

  private func configureTimeObserver() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: observerInterval,
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let seconds = time.seconds
        if seconds.isFinite {
          self.currentTime = seconds
        }
        self.isPlaying = self.player.rate != 0
        if let previewRange = self.previewRange,
           seconds >= previewRange.upperBound {
          self.seekPreservingPreview(to: previewRange.lowerBound)
          self.player.play()
          self.isPlaying = true
        }
      }
    }
  }
}
