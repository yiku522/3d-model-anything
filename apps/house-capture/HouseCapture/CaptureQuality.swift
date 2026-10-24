import Foundation

/// Pure policies: guidance never prevents saving partial work.
struct CaptureQuality {
  let percent: Int
  let walls: Int
  let photos: Int
  var ready: Bool { walls >= 3 && photos >= 8 && percent >= 85 }
  var message: String {
    if walls < 3 { return "正在测量房间并自动保存照片。" }
    if photos < 8 { return "扫描时自动采集有用的视角。" }
    if ready { return "拍照细节良好。保存后检查遗漏区域。" }
    return "在你走动时，照片会自动保存。"
  }
}

struct CaptureBudget {
  let constrained: Bool
  let critical: Bool
  init(thermal: ProcessInfo.ThermalState, photos: Int, memoryPressure: Bool) {
    critical = thermal == .critical
    constrained = memoryPressure || photos >= 150 || thermal == .serious || critical
  }
  var depthInterval: Double { critical ? 1 : constrained ? 0.5 : 0.2 }
  var evaluationInterval: Double { constrained ? 0.3 : 0.1 }
  var photoInterval: Double { constrained ? 1.2 : 0.4 }
}
