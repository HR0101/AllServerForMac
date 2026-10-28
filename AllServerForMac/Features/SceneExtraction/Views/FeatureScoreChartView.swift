// AllServerForMac/Features/SceneExtraction/Views/FeatureScoreChartView.swift

import Charts
import SwiftUI

struct FeatureScoreChartView: View {
  let features: [FeatureVector]

  var body: some View {
    SectionCard(title: "特徴量スコア") {
      if features.isEmpty {
        ContentUnavailableView(
          "解析結果がありません",
          systemImage: "chart.xyaxis.line",
          description: Text("動画を解析するとA・B・Cと合成スコアを表示します．")
        )
      } else {
        Chart(features) { feature in
          LineMark(
            x: .value("時刻", feature.time),
            y: .value("スコア", feature.audioBandEnergy),
            series: .value("系列", "音声 A")
          )
          .foregroundStyle(by: .value("系列", "音声 A"))

          LineMark(
            x: .value("時刻", feature.time),
            y: .value("スコア", feature.visualMotion),
            series: .value("系列", "映像 B")
          )
          .foregroundStyle(by: .value("系列", "映像 B"))

          LineMark(
            x: .value("時刻", feature.time),
            y: .value("スコア", transitionScore(feature)),
            series: .value("系列", "遷移 C")
          )
          .foregroundStyle(by: .value("系列", "遷移 C"))

          LineMark(
            x: .value("時刻", feature.time),
            y: .value("スコア", feature.combinedScore),
            series: .value("系列", "合成")
          )
          .foregroundStyle(by: .value("系列", "合成"))
          .lineStyle(StrokeStyle(lineWidth: 2.5))
        }
        // 音声・映像・遷移は明るさの違う無彩色にし、結論である合成スコアだけを青の太線にする。
        .chartForegroundStyleScale([
          "音声 A": NeomorphicTheme.ink.opacity(0.38),
          "映像 B": NeomorphicTheme.ink.opacity(0.58),
          "遷移 C": NeomorphicTheme.ink.opacity(0.80),
          "合成": NeomorphicTheme.accent,
        ])
        .chartYScale(domain: 0...1)
        .chartXAxisLabel("時刻［秒］")
        .chartYAxisLabel("正規化スコア")
      }
    }
  }

  private func transitionScore(_ feature: FeatureVector) -> Double {
    max(
      feature.freezeScore,
      feature.dissolveScore,
      feature.fadeScore,
      feature.editScore
    )
  }
}
