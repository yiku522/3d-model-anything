import SwiftUI
import AVFoundation

struct CaptureReadinessError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum CaptureReadiness {
  static let reserve: Int64 = 500_000_000
  static let pauseReserve: Int64 = 200_000_000
  static func available(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
  }
  static func requireStorage(at url: URL, bytes: Int64 = reserve) throws {
    try checkStorage(available: available(at: url), required: bytes)
  }
  static func checkStorage(available: Int64?, required: Int64) throws {
    if let available, available < required {
      throw CaptureReadinessError(message: "Not enough storage. Free at least \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) on this device, then try again. Saved scans are kept.")
    }
  }
  @MainActor static func prepare() async throws {
    guard CaptureController.isSupported else {
      throw CaptureReadinessError(message: "Scanning needs a LiDAR-equipped iPhone Pro or iPad Pro. You can import, view and share existing scans on this device.")
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        throw CaptureReadinessError(message: "Camera access is off. Enable Camera for 3D Model Anything in Settings, then try scanning again.")
      }
    case .denied:
      throw CaptureReadinessError(message: "Camera access is off. Enable Camera for 3D Model Anything in Settings, then try scanning again.")
    case .restricted:
      throw CaptureReadinessError(message: "Camera access is restricted on this device. Check Screen Time or device-management restrictions. You can still import and view scans.")
    @unknown default:
      throw CaptureReadinessError(message: "Camera access is unavailable. You can still import and view scans.")
    }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try requireStorage(at: docs)
  }
}

struct HelpDocument: Decodable {
  struct Section: Decodable, Identifiable {
    let title: String
    let body: String
    var id: String { title }
  }
  let title: String
  let updated: String
  let sections: [Section]
  static func load(_ name: String) -> HelpDocument? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

struct HelpDocumentView: View {
  let resource: String
  var body: some View {
    ScrollView {
      if let document = HelpDocument.load(resource) {
        VStack(alignment: .leading, spacing: 24) {
          Text(document.title).font(.largeTitle.bold())
          FieldworkEyebrow(text: "Updated \(document.updated)")
          ForEach(document.sections) { section in
            VStack(alignment: .leading, spacing: 8) {
              Text(section.title).font(.headline)
              Text(section.body).foregroundStyle(Fieldwork.secondary).textSelection(.enabled)
            }
          }
        }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
      } else {
        ContentUnavailableView("帮助暂不可用", systemImage: "doc.text", description: Text("请重新安装应用更新，以恢复内置的帮助内容。"))
      }
    }.background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
  }
}

struct AppHelpScreen: View {
  private func publicURL(_ key: String) -> URL? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
          let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
    return url
  }
  var body: some View {
    List {
      Section("3D 实景建模") {
        NavigationLink("扫描、导入与分享") { HelpDocumentView(resource: "Support") }
        NavigationLink("隐私政策") { HelpDocumentView(resource: "PrivacyPolicy") }
        if let url = publicURL("HouseCapturePrivacyURL") { Link("在线隐私政策", destination: url) }
        if let url = publicURL("HouseCaptureSupportURL") { Link("联系支持", destination: url) }
      }
      Section("权限") {
        Text("摄像头仅在扫描房间时使用。导入和查看已保存的扫描不需要摄像头权限。")
        Button("打开应用设置") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
      }
      Section("关于") {
        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
        Text("扫描结果仅为近似值。在进行施工或其他精密工作前，请务必核对测量结果。").font(.footnote)
      }
    }
    .scrollContentBackground(.hidden).background(Fieldwork.paper)
    .navigationTitle("帮助与隐私").navigationBarTitleDisplayMode(.inline)
  }
}
