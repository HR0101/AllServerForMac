import Combine
import Darwin
import Foundation

struct CPUDataPoint: Identifiable {
    let id = UUID()
    let time: Int
    let value: Double
}

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsage: Double = 0.0
    @Published var cpuHistory: [CPUDataPoint] = []

    private var timer: Timer?
    private var previousInfo: host_cpu_load_info?
    private var counter = 0

    init() {
        for i in 0..<30 {
            cpuHistory.append(CPUDataPoint(time: i - 30, value: 0))
        }
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateStats() {
        let cpu = getCPUUsage()
        let mem = getMemoryUsage()

        DispatchQueue.main.async {
            self.cpuUsage = cpu
            self.memoryUsage = mem
            self.counter += 1
            self.cpuHistory.append(CPUDataPoint(time: self.counter, value: cpu))
            if self.cpuHistory.count > 30 {
                self.cpuHistory.removeFirst()
            }
        }
    }

    private func getCPUUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoadInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        if result == KERN_SUCCESS {
            if let prev = previousInfo {
                let userDiff = Double(cpuLoadInfo.cpu_ticks.0 - prev.cpu_ticks.0)
                let sysDiff = Double(cpuLoadInfo.cpu_ticks.1 - prev.cpu_ticks.1)
                let idleDiff = Double(cpuLoadInfo.cpu_ticks.2 - prev.cpu_ticks.2)
                let niceDiff = Double(cpuLoadInfo.cpu_ticks.3 - prev.cpu_ticks.3)

                let totalTicks = userDiff + sysDiff + idleDiff + niceDiff
                let activeTicks = userDiff + sysDiff + niceDiff

                previousInfo = cpuLoadInfo
                return totalTicks > 0 ? (activeTicks / totalTicks) * 100.0 : 0.0
            } else {
                previousInfo = cpuLoadInfo
                return 0.0
            }
        }
        return 0.0
    }

    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let active = Double(stats.active_count) * Double(vm_page_size)
            let wire = Double(stats.wire_count) * Double(vm_page_size)
            let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)

            let usedMemory = active + wire + compressed
            let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)

            return physicalMemory > 0 ? (usedMemory / physicalMemory) * 100.0 : 0.0
        }
        return 0.0
    }
}
