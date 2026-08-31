// AllServerForMac/Features/SceneExtraction/Views/SceneExtractionView.swift

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneExtractionView: View {
  @ObservedObject var viewModel: SceneExtractionViewModel

  private let minimumPlayerWidth: CGFloat = 560
  private let minimumChartWidth: CGFloat = 360
  private let candidateListHeight: CGFloat = 230

  var body: some View {
    VStack(spacing: 14) {
      header
      if let progress = viewModel.analysisProgress {
        HStack(spacing: 10) {
          ProgressView(value: progress.fractionCompleted)
          Text("\(progress.stage.displayName) \(Int(progress.fractionCompleted * 100))％")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .trailing)
        }
      }
      outputControls

      HSplitView {
        AnalysisPlayerView(viewModel: viewModel)
          .frame(minWidth: minimumPlayerWidth)

        VStack(spacing: 12) {
          FeatureScoreChartView(features: viewModel.features)
          ScrollView {
            SceneExtractionSettingsView(settings: $viewModel.settings)
          }
          .frame(maxHeight: 330)
        }
        .frame(minWidth: minimumChartWidth)
      }

      CandidateListView(
        candidates: viewModel.candidates,
        selectedCandidateID: viewModel.selectedCandidateID,
        canExport: viewModel.outputDirectoryURL != nil && !viewModel.isExportingClip,
        onSelect: viewModel.selectCandidate,
        onPreview: viewModel.previewCandidate,
        onLabel: viewModel.setLabel,
        onUpdateStart: viewModel.updateCandidateStart,
        onUpdateEnd: viewModel.updateCandidateEnd,
        onExport: viewModel.exportClip
      )
      .frame(height: candidateListHeight)
    }
    .padding(16)
    .background(NeomorphicTheme.background)
    .navigationTitle("シーン抽出")
    .alert(
      "処理に失敗しました",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("OK", role: .cancel) {
        viewModel.clearError()
      }
    } message: {
      Text(viewModel.errorMessage ?? "不明なエラーです．")
    }
    .alert(
      "処理が完了しました",
      isPresented: Binding(
        get: { viewModel.lastOperationMessage != nil },
        set: { if !$0 { viewModel.lastOperationMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {
        viewModel.lastOperationMessage = nil
      }
    } message: {
      Text(viewModel.lastOperationMessage ?? "")
    }
  }

  private var outputControls: some View {
    HStack(spacing: 10) {
      Button {
        selectOutputDirectory()
      } label: {
        Label("ComfyUI出力先", systemImage: "folder.badge.gearshape")
      }

      Text(viewModel.outputDirectoryURL?.path ?? "出力先が選択されていません")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      if viewModel.isExportingClip || viewModel.isExportingDataset {
        ProgressView()
          .controlSize(.small)
      }

      Button {
        viewModel.exportDataset()
      } label: {
        Label("JSON・CSVを保存", systemImage: "tablecells")
      }
      .disabled(
        viewModel.videoDocument == nil
          || viewModel.outputDirectoryURL == nil
          || viewModel.isExportingClip
          || viewModel.isExportingDataset
      )
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button {
        openVideo()
      } label: {
        Label("動画を開く", systemImage: "folder")
      }
      .disabled(viewModel.isLoadingVideo)

      if viewModel.isAnalyzing {
        Button(role: .cancel) {
          viewModel.cancelAnalysis()
        } label: {
          Label("解析をキャンセル", systemImage: "xmark.circle")
        }
      } else {
        Button {
          viewModel.startAnalysis()
        } label: {
          Label("候補を解析", systemImage: "waveform.path.ecg")
        }
        .disabled(viewModel.videoDocument == nil || viewModel.isLoadingVideo)
      }

      Toggle("GTラベル付与モード", isOn: $viewModel.isGroundTruthModeEnabled)
        .toggleStyle(.switch)

      Button {
        viewModel.addGroundTruthAtCurrentTime()
      } label: {
        Label("現在位置を正解にする", systemImage: "checkmark.seal")
      }
      .disabled(!viewModel.isGroundTruthModeEnabled || viewModel.videoDocument == nil)

      Spacer()

      if let document = viewModel.videoDocument {
        VStack(alignment: .trailing, spacing: 2) {
          Text(document.url.lastPathComponent)
            .font(.headline)
            .lineLimit(1)
          Text(metadataText(document))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func openVideo() {
    let panel = NSOpenPanel()
    panel.title = "解析する動画を選択"
    panel.allowedContentTypes = [.movie]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await viewModel.loadVideo(from: url)
    }
  }

  private func selectOutputDirectory() {
    let panel = NSOpenPanel()
    panel.title = "ComfyUIのinputフォルダを選択"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    viewModel.setOutputDirectory(url)
  }

  private func metadataText(_ document: VideoDocument) -> String {
    let audioText = document.hasAudioTrack ? "音声あり" : "音声なし"
    return String(
      format: "%d×%d・%.2ffps・%@",
      document.resolutionWidth,
      document.resolutionHeight,
      document.nominalFrameRate,
      audioText
    )
  }
}
