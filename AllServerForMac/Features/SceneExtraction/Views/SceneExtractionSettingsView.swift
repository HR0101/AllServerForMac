// AllServerForMac/Features/SceneExtraction/Views/SceneExtractionSettingsView.swift

import SwiftUI

struct SceneExtractionSettingsView: View {
  @Binding var settings: AnalysisSettings

  var body: some View {
    GroupBox("解析・書き出し設定") {
      Form {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          valueRow("候補区間［秒］") {
            TextField("秒", value: $settings.clipDuration, format: .number.precision(.fractionLength(1)))
          }
          valueRow("ピークまで［秒］") {
            TextField("秒", value: $settings.peakLeadTime, format: .number.precision(.fractionLength(1)))
          }
          valueRow("出力fps") {
            TextField("fps", value: $settings.targetFramesPerSecond, format: .number)
          }
          valueRow("出力フレーム数") {
            TextField("frames", value: $settings.targetFrameCount, format: .number)
          }
          valueRow("候補しきい値") {
            TextField("0〜1", value: $settings.candidateThreshold, format: .number.precision(.fractionLength(2)))
          }
          valueRow("候補間隔［秒］") {
            TextField("秒", value: $settings.minimumCandidateDistance, format: .number.precision(.fractionLength(1)))
          }
          valueRow("freezeしきい値") {
            TextField("0〜1", value: $settings.freezeThreshold, format: .number.precision(.fractionLength(3)))
          }
          valueRow("解析fps") {
            TextField("fps", value: $settings.analysisFramesPerSecond, format: .number.precision(.fractionLength(1)))
          }
          valueRow("音声の重み") {
            TextField("weight", value: $settings.audioWeight, format: .number.precision(.fractionLength(2)))
          }
          valueRow("映像の重み") {
            TextField("weight", value: $settings.visualWeight, format: .number.precision(.fractionLength(2)))
          }
          valueRow("遷移の重み") {
            TextField("weight", value: $settings.transitionWeight, format: .number.precision(.fractionLength(2)))
          }
        }

        Divider()

        Toggle("音声を含める", isOn: $settings.includesAudio)
        Toggle("HEVCで書き出す", isOn: $settings.usesHEVC)
        Toggle("sidecar JSONを出力", isOn: $settings.writesSidecarJSON)
        Toggle("特徴量CSVを出力", isOn: $settings.writesDatasetCSV)

        Text(String(format: "実出力時間 %.3f秒", settings.outputDuration))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .formStyle(.grouped)
    }
  }

  private func valueRow<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GridRow {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
        .textFieldStyle(.roundedBorder)
        .frame(width: 90)
    }
  }
}
