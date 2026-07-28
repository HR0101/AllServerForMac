import Foundation

/// CPU使用率の時系列データを表すDashboard Modelです．
struct CPUDataPoint: Identifiable {
  let id = UUID()
  let time: Int
  let value: Double
}
