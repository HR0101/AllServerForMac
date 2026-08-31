// AllServerForMac/Features/SceneExtraction/Views/CandidateListView.swift

import SwiftUI

struct CandidateListView: View {
  let candidates: [CandidateSegment]
  let selectedCandidateID: UUID?
  let canExport: Bool
  let onSelect: (CandidateSegment) -> Void
  let onPreview: (CandidateSegment) -> Void
  let onLabel: (CandidateLabel, UUID) -> Void
  let onUpdateStart: (Double, UUID) -> Void
  let onUpdateEnd: (Double, UUID) -> Void
  let onExport: (CandidateSegment) -> Void

  var body: some View {
    GroupBox("候補区間") {
      if candidates.isEmpty {
        ContentUnavailableView(
          "候補がありません",
          systemImage: "scope",
          description: Text("解析後の候補または手動GTがここに表示されます．")
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(candidates.sorted { $0.score > $1.score }) { candidate in
              candidateRow(candidate)
            }
          }
        }
      }
    }
  }

  private func candidateRow(_ candidate: CandidateSegment) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text("ピーク \(timeText(candidate.peakTime))")
            .font(.headline)
          Text(String(format: "score %.3f", candidate.score))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 5) {
          Text("start")
          TextField(
            "start",
            value: Binding(
              get: { candidate.startTime },
              set: { onUpdateStart($0, candidate.id) }
            ),
            format: .number.precision(.fractionLength(2))
          )
          Text("end")
          TextField(
            "end",
            value: Binding(
              get: { candidate.endTime },
              set: { onUpdateEnd($0, candidate.id) }
            ),
            format: .number.precision(.fractionLength(2))
          )
        }
        .font(.system(.caption, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 245)

        Text(candidate.reason.joined(separator: "，"))
          .font(.caption)
          .lineLimit(1)
      }

      Spacer()

      Text(String(format: "A %.2f  B %.2f  C %.2f", candidate.audioScore, candidate.visualScore, candidate.transitionScore))
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)

      Picker(
        "ラベル",
        selection: Binding(
          get: { candidate.userLabel ?? .uncertain },
          set: { onLabel($0, candidate.id) }
        )
      ) {
        ForEach(CandidateLabel.allCases, id: \.self) { label in
          Text(label.displayName).tag(label)
        }
      }
      .labelsHidden()
      .frame(width: 88)

      Button("プレビュー") {
        onPreview(candidate)
      }

      Button("書き出し") {
        onExport(candidate)
      }
      .disabled(!canExport)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(candidate.id == selectedCandidateID ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect(candidate)
    }
  }

  private func timeText(_ seconds: Double) -> String {
    let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
    let hours = Int(safeSeconds) / 3_600
    let minutes = Int(safeSeconds) % 3_600 / 60
    let remainingSeconds = Int(safeSeconds) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
  }
}
