import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct HouseCaptureApp: App {
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if let preview = PreviewDebug.launchView() {
        preview // -preview-house <folder> (see PreviewDebug.swift)
      } else if args.contains("-diag") {
        DiagnosticsView()
      } else if args.contains("-selftest") {
        SelfTestView()
      } else if args.contains("-autotest") || args.contains("-autotest-continue") {
        AutoTestView(continueLatest: args.contains("-autotest-continue"))
      } else {
        HomeView()
      }
      #else
      HomeView()
      #endif
    }
  }
}

/// Houses scanned over several sessions
struct HomeView: View {
  @State private var houses: [HouseProject] = []
  @State private var path: [String] = [] // house ids
  @State private var capture: CaptureController?
  @State private var error: String?
  @State private var naming = false
  @State private var importing = false
  @State private var working = false
  @State private var newName = ""
  @State private var deleting: HouseProject?
  /// bumped when a capture closes so the house screen reloads
  @State private var generation = 0
  @State private var openedFromArgs = false

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 14) {
            FieldworkEyebrow(text: "记录你的空间")
            Text("3D 实景建模").font(.largeTitle.weight(.bold)).tracking(-1)
            Text("一间一间，记录每个细节。").font(.title3).foregroundStyle(Fieldwork.secondary)
          }.padding(.top, 20).padding(.bottom, 36)
          FieldworkRule()
          if houses.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
              Image(systemName: "house.lodge").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Fieldwork.orange)
              Text("从你熟悉的空间开始。").font(.title2.bold())
              Text("先创建一个房屋，然后扫描你的第一个房间。你的扫描和照片都会保存在这部 iPhone 上。")
                .foregroundStyle(Fieldwork.secondary)
            }.padding(.vertical, 40)
          }
          ForEach(Array(houses.enumerated()), id: \.element.id) { number, house in
            NavigationLink(value: house.id) {
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  FieldworkEyebrow(text: String(format: "%02d / HOUSE", number + 1))
                  Spacer()
                  Image(systemName: "arrow.up.right").foregroundStyle(Fieldwork.orange)
                }
                HouseRow(house: house)
                if let active = house.rooms.first?.active, let session = house.session(active.session) {
                  FieldworkThumbnail(folder: house.bundle(for: session).url, index: active.index).frame(height: 180).frame(maxWidth: .infinity)
                }
              }.padding(.vertical, 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu {
              Button("删除房屋", systemImage: "trash", role: .destructive) { deleting = house }
            }
            FieldworkRule()
          }
          if !CaptureController.isSupported {
            Text("扫描需要使用带 LiDAR 的 iPhone 或 iPad。导入已解包的房间文件夹，即可在此设备上查看和分享扫描。")
              .font(.footnote).foregroundStyle(Fieldwork.secondary).padding(.vertical, 24)
          }
        }.padding(.horizontal, 24).padding(.bottom, 24)
      }
      .disabled(working)
      .overlay { if working { ProgressView("准备中…").padding(24).background(Fieldwork.paper, in: RoundedRectangle(cornerRadius: 12)) } }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
            .accessibilityLabel("导入房间文件夹").disabled(working)
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink { AppHelpScreen() } label: { Image(systemName: "questionmark.circle").frame(width: 44, height: 44) }.accessibilityLabel("帮助与隐私")
        }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
        switch result {
        case .success(let url): importFolder(url)
        case .failure(let e): error = e.localizedDescription
        }
      }
      .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
      .navigationTitle("").navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Button {
          newName = houses.isEmpty ? "我们的家" : ""
          naming = true
        } label: { Label("新建房屋", systemImage: "plus") }
          .buttonStyle(FieldworkButtonStyle()).disabled(!CaptureController.isSupported)
          .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Fieldwork.paper)
      }
      .navigationDestination(for: String.self) { id in
        HouseScreen(houseID: id, generation: generation, onCapture: startCapture, onGone: { path.removeAll() })
      }
      .onAppear(perform: reload)
      .alert("出现了问题", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("好") { error = nil }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
          Button("打开设置") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
        }
      } message: {
        Text(error ?? "")
      }
      .alert("新建房屋", isPresented: $naming) {
        TextField("名称", text: $newName)
        Button("创建并扫描", action: createHouse)
        Button("取消", role: .cancel) {}
      } message: {
        Text("然后扫描你的第一个房间。之后你可以随时添加更多房间。")
      }
      .confirmationDialog("删除 \(deleting?.name ?? "房屋")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        Button("删除房屋及其所有扫描", role: .destructive) {
          if let h = deleting {
            do { try h.delete() } catch { self.error = error.localizedDescription }
          }
          deleting = nil
          reload()
        }
      } message: {
        Text("这将从手机上删除该房屋的所有会话、照片和网格。")
      }
      .fullScreenCover(item: $capture, onDismiss: captureClosed) { controller in
        CaptureScreen(controller: controller) { capture = nil }
      }
    }
    .tint(Fieldwork.orange)
    .preferredColorScheme(.light)
    .toolbarBackground(Fieldwork.paper, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
  }

  private func reload() {
    houses = HouseProject.all()
    // `-house <id>`: open that house directly (screenshots, debugging)
    let args = ProcessInfo.processInfo.arguments
    if path.isEmpty, !openedFromArgs, let i = args.firstIndex(of: "-house"), i + 1 < args.count {
      openedFromArgs = true
      path = [args[i + 1]]
    }
  }

  private func captureClosed() {
    generation += 1
    reload()
  }

  private func createHouse() {
    guard !working else { return }
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    working = true
    Task {
      defer { working = false }
      do {
        try await CaptureReadiness.prepare()
        var house = try HouseProject.create(name: name.isEmpty ? "House" : name)
        let zone = house.addZone(named: "Area 1")
        try house.save()
        reload()
        path = [house.id]
        try? await Task.sleep(for: .milliseconds(450))
        capture = try CaptureController.start(houseID: house.id, zoneID: zone.id)
      } catch { self.error = error.localizedDescription }
    }
  }

  private func startCapture(houseID: String, zoneID: String?, newZone: String?, roomID: String? = nil) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await CaptureReadiness.prepare()
        capture = try CaptureController.start(houseID: houseID, zoneID: zoneID, newZone: newZone)
        if let roomID, let room = try HouseProject.load(id: houseID).rooms.first(where: { $0.id == roomID }) {
          capture?.selectedRoomID = room.id
          capture?.roomName = room.name
        }
      } catch { self.error = error.localizedDescription }
    }
  }

  private func importFolder(_ url: URL) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let id = try await Task.detached(priority: .userInitiated) { try ScanImport.importFolder(url) }.value
        reload(); path = [id]
      } catch { self.error = error.localizedDescription }
    }
  }


}

private struct HouseRow: View {
  let house: HouseProject
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(house.name).font(.title2.bold()).foregroundStyle(Fieldwork.ink)
      Text(summary).font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var summary: String {
    let rooms = house.rooms.count, sessions = house.sessions.count
    var s = "\(rooms) 个房间 · \(sessions) 次会话"
    if house.zones.count > 1 { s += " · \(house.zones.count) 个区域" }
    if let last = house.sessions.map(\.startedAt).max() { s += " · 最近于 \(last.formatted(date: .abbreviated, time: .shortened))" }
    return s
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeCoordinator() -> [URL] { items.compactMap { $0 as? URL } }
  static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: [URL]) {
    for url in coordinator { FolderZipper.removeArchive(url) }
  }
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
  public var id: String { absoluteString }
}

extension CaptureController: Identifiable {}
