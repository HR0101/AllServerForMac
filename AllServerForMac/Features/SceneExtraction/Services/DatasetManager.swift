// AllServerForMac/Features/SceneExtraction/Services/DatasetManager.swift

import Foundation

nonisolated struct DatasetExportResult: Sendable {
  let jsonURL: URL
  let csvURL: URL?
}

nonisolated struct DatasetManager: Sendable {
  func export(
    document: VideoDocument,
    settings: AnalysisSettings,
    analysisResult: VideoAnalysisResult?,
    candidates: [CandidateSegment],
    outputDirectory: URL,
    includesCSV: Bool
  ) async throws -> DatasetExportResult {
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
      )
      let fileStem = makeFileStem(document: document)
      let jsonURL = outputDirectory.appendingPathComponent("\(fileStem)_analysis.json")
      let csvURL = includesCSV
        ? outputDirectory.appendingPathComponent("\(fileStem)_features.csv")
        : nil
      let updatedResult = makeUpdatedResult(
        document: document,
        settings: settings,
        analysisResult: analysisResult,
        candidates: candidates
      )
      try writeJSON(updatedResult, to: jsonURL)
      if let csvURL {
        try writeCSV(result: updatedResult, candidates: candidates, to: csvURL)
      }
      return DatasetExportResult(jsonURL: jsonURL, csvURL: csvURL)
    }.value
  }

  private func makeUpdatedResult(
    document: VideoDocument,
    settings: AnalysisSettings,
    analysisResult: VideoAnalysisResult?,
    candidates: [CandidateSegment]
  ) -> VideoAnalysisResult {
    VideoAnalysisResult(
      document: document,
      settings: settings,
      audioFeatures: analysisResult?.audioFeatures ?? [],
      visualFeatures: analysisResult?.visualFeatures ?? [],
      transitionFeatures: analysisResult?.transitionFeatures ?? [],
      mergedFeatures: analysisResult?.mergedFeatures ?? [],
      candidates: candidates,
      createdAt: analysisResult?.createdAt ?? Date()
    )
  }

  private func writeJSON(_ result: VideoAnalysisResult, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(result).write(to: url, options: .atomic)
  }

  private func writeCSV(
    result: VideoAnalysisResult,
    candidates: [CandidateSegment],
    to url: URL
  ) throws {
    var rows = [
      "source_id,time,audio_band_energy,audio_rise,audio_decay,visual_motion,visual_spike,visual_drop,freeze_score,dissolve_score,fade_score,edit_score,combined_score,label"
    ]
    rows.reserveCapacity(result.mergedFeatures.count + 1)
    let sourceID = result.document.id.uuidString

    for feature in result.mergedFeatures {
      try Task.checkCancellation()
      let label = label(at: feature.time, candidates: candidates)?.rawValue ?? ""
      rows.append(
        [
          sourceID,
          decimal(feature.time),
          decimal(feature.audioBandEnergy),
          decimal(feature.audioRise),
          decimal(feature.audioDecay),
          decimal(feature.visualMotion),
          decimal(feature.visualSpike),
          decimal(feature.visualDrop),
          decimal(feature.freezeScore),
          decimal(feature.dissolveScore),
          decimal(feature.fadeScore),
          decimal(feature.editScore),
          decimal(feature.combinedScore),
          label
        ].joined(separator: ",")
      )
    }
    let csv = rows.joined(separator: "\n") + "\n"
    try Data(csv.utf8).write(to: url, options: .atomic)
  }

  private func label(at time: Double, candidates: [CandidateSegment]) -> CandidateLabel? {
    candidates
      .filter { $0.userLabel != nil && $0.startTime <= time && time <= $0.endTime }
      .min { abs($0.peakTime - time) < abs($1.peakTime - time) }?
      .userLabel
  }

  private func decimal(_ value: Double) -> String {
    String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private func makeFileStem(document: VideoDocument) -> String {
    let sourceName = sanitizedFileName(document.url.deletingPathExtension().lastPathComponent)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return "\(sourceName)_\(formatter.string(from: Date()))"
  }

  private func sanitizedFileName(_ fileName: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitizedScalars = fileName.unicodeScalars.map { scalar in
      allowedCharacters.contains(scalar) ? String(scalar) : "_"
    }
    let result = sanitizedScalars.joined()
    return result.isEmpty ? "dataset" : result
  }
}
