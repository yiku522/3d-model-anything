import ARKit
import RoomPlan
import SwiftUI

/// Full-screen capture: one pass per room. Camera + coverage mesh + RoomPlan's live walls.
struct CaptureScreen: View {
  @ObservedObject var controller: CaptureController
  let onClose: () -> Void
  @State private var reviewing = false
  @State private var confirmClose = false
  @FocusState private var nameFocused: Bool
  @Environment(\.scenePhase) private var scenePhase
  static let roomSuggestions = ["客厅", "厨房", "餐厅", "书房", "卧室", "Primary bedroom", "浴室", "走廊", "Basement", "Playroom", "Laundry", "Garage"]

  private var scanning: Bool { controller.phase == .scanning }

  var body: some View {
    ZStack {
      ARViewContainer(view: controller.scanView.view).ignoresSafeArea()

      VStack {
        topBar
        if let notice = controller.notice {
          Label(notice, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .transition(.opacity)
        }
        Spacer()
        if scanning, let issue = controller.trackingIssue {
          VStack(alignment: .leading, spacing: 6) {
            Label("正在恢复你的位置", systemImage: "viewfinder.trianglebadge.exclamationmark")
              .font(.headline)
            Text(issue.message).font(.subheadline)
            Text("录制已暂停。已保存的照片是安全的；当你的位置稳定后，扫描会自动继续。").font(.caption)
            if let url = controller.recoveryPhoto, let image = UIImage(contentsOfFile: url.path) {
              Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
              Text("返回此界面并缓慢平移。").font(.caption)
            }
            Button("保存现有内容", action: controller.finishRoom)
          }
          .padding(12)
          .frame(maxWidth: 500, alignment: .leading)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal)
          .accessibilityElement(children: .combine)
        }
        if let warning = controller.lastWarning {
          Text(warning)
            .font(.footnote)
            .padding(10)
            .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
        bottomPanel
      }
      .padding(.bottom, 8)
      .animation(.easeInOut(duration: 0.3), value: controller.notice)
    }
    .confirmationDialog("离开本次会话？", isPresented: $confirmClose, titleVisibility: .visible) {
      if !controller.rooms.isEmpty && controller.phase == .betweenRooms {
        Button("保存 \(controller.rooms.count) 个房间 并完成") {
          Task { await controller.finishSession() }
        }
      }
      Button(controller.rooms.isEmpty ? "丢弃会话" : "Discard session and its \(controller.rooms.count) room\(controller.rooms.count == 1 ? "" : "s")", role: .destructive) {
        controller.abandon()
        onClose()
      }
      Button("继续扫描", role: .cancel) {}
    }
    .sheet(isPresented: $reviewing) {
      if let source = controller.reviewSource {
        NavigationStack { ScanReview(source: source).toolbar { Button("完成") { reviewing = false } } }
      }
    }
    .onChange(of: controller.phase) { old, next in
      if old == .finishingRoom, next == .betweenRooms, controller.reviewSource != nil, !controller.captureBudget.constrained { reviewing = true }
    }
    .onAppear { controller.begin() }
    .onChange(of: scenePhase) { _, phase in
      // leaving the app interrupts the camera: don't keep counting coverage across the gap
      if phase != .active { controller.pause() }
    }
    .statusBarHidden()
  }

  // MARK: top

  private var topBar: some View {
    HStack(alignment: .top) {
      Button {
        if controller.phase == .done { onClose() } else { confirmClose = true }
      } label: {
        Image(systemName: "xmark")
          .font(.headline)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 10) {
          if scanning {
            VStack(spacing: 3) {
              CoverageRing(percent: controller.stats.percent).frame(width: 44, height: 44)
              Text("拍照细节").font(.system(size: 9, weight: .semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo detail, \(controller.stats.percent) percent of observed surfaces")
          }
          VStack(alignment: .trailing, spacing: 2) {
            if scanning {
              Text(controller.roomName).font(.headline)
              Text(controller.meshReady ? "\(controller.coverage.walls.count) walls measured" : "Starting LiDAR…")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Text("\(controller.rooms.count) room\(controller.rooms.count == 1 ? "" : "s") · \(controller.photoCount) photos")
              .font(.caption.monospacedDigit())
            if controller.phase != .relocalizing {
              HStack(spacing: 6) {
                AlignmentBadge(alignment: controller.alignment)
                MapStatusDot(status: controller.mappingStatus)
              }
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        if controller.hasGhost, controller.alignment.method == "relocalized", controller.phase == .betweenRooms || scanning {
          Toggle(isOn: $controller.ghostVisible) {
            Label("早前扫描", systemImage: controller.ghostVisible ? "eye" : "eye.slash")
              .font(.caption.weight(.semibold))
          }
          .toggleStyle(.button)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.green)
        }
        if scanning {
          liveMap
        }
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
  }

  /// Heading-up map: walls go green once a sharp photo sees them roughly head-on
  private var liveMap: some View {
    VStack(spacing: 4) {
      CoverageMap(coverage: controller.coverage, camera: controller.cameraPose, photos: controller.photoPositions,
                  redSpots: controller.stats.redSpots)
        .frame(width: 130, height: 130)
    }
    .padding(8)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  // MARK: bottom

  @ViewBuilder
  private var bottomPanel: some View {
    switch controller.phase {
    case .relocalizing:
      RelocalizationPanel(controller: controller)
    case .betweenRooms:
      if controller.sessionNeedsRestart {
        panel {
          Label("扫描已结束", systemImage: "exclamationmark.triangle.fill").font(.headline)
          Text("手机丢失了位置信息。可用的房间数据已保存。请结束本次会话，然后从房屋主界面开始一次新的扫描。")
            .font(.subheadline)
          roomList
          Button("完成并保留已保存的房间") { Task { await controller.finishSession() } }
            .buttonStyle(.borderedProminent)
        }
      } else { betweenRooms }
    case .scanning:
      if controller.paused { pausedPanel } else { scanControls }
    case .finishingRoom:
      status("Saving \(controller.roomName)…")
    case .finishing:
      status(controller.finishingStep.isEmpty ? "Saving…" : controller.finishingStep)
    case .done:
      done
    case .failed(let message):
      panel {
        Text("无法保存扫描").font(.headline)
        Text(message).font(.footnote)
        Text("清理存储空间时请保持此界面打开，然后重试。已经写入的文件会被保留。").font(.caption)
        Button("重试保存") { Task { await controller.finishSession() } }.buttonStyle(.borderedProminent)
        Button("关闭", action: onClose).buttonStyle(.bordered)
      }
    }
  }

  private var betweenRooms: some View {
    panel {
      if controller.rooms.isEmpty {
        if controller.alignment.method == "relocalized" {
          Text("You're lined up with \(controller.zoneName). The faint green is what you scanned before\(controller.priorPhotoCount > 0 ? "; surfaces its \(controller.priorPhotoCount) photos already cover start out green" : ""). Scan a new room, or rescan one to replace it.")
            .font(.subheadline)
        } else {
          Text("每个房间扫描一次：移动时会出现三角网格。**绿色**表示照片覆盖良好（包括已对齐的早前扫描）。**红色**需要更多照片。没有三角网格的区域仍需要扫描。白色轮廓是正在测量的墙体、门和窗。**拍照细节**衡量 LiDAR 已观测表面上的拍照情况，并非房间被扫描的百分比。保存后检查遗漏区域。")
            .font(.subheadline)
        }
      } else {
        CoverageMap(coverage: controller.coverage, camera: nil, photos: controller.photoPositions)
          .frame(height: 150)
          .frame(maxWidth: .infinity)
        if let last = controller.rooms.last {
          Text("\(last.name): \(last.photographedPercent.map { "\($0)% 拍照细节" } ?? "未测量") · \(last.detailPhotos ?? 0) 张照片\(last.mesh == nil ? " · 无网格" : "")")
            .font(.footnote)
        }
        Button("在 3D 中查看已保存的房间") { reviewing = true }.buttonStyle(.borderedProminent)
        Text("离开前先查看带贴图的扫描。在预览中用覆盖色检查遗漏区域。").font(.caption)
        roomList
        Text("走进下一个房间，然后开始扫描。保持在同一会话中，这样房间才能对齐。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if controller.requiresFreshScan {
        Text("本次扫描已保存。结束本次会话，然后点击“扫描一个房间”以开始一次新的扫描。").font(.headline)
      }
      Text("你现在在哪个房间？").font(.subheadline.weight(.semibold))
      TextField("房间名称", text: $controller.roomName)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.go)
        .focused($nameFocused)
        .onSubmit(controller.startRoom)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          // rooms scanned before in this area first: picking one rescans (replaces) it
          ForEach(controller.existingRooms) { existing in
            let name = existing.name
            Button {
              controller.selectRoom(existing)
            } label: {
              Label(name, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(controller.roomName == name ? .accentColor : .green)
          }
          ForEach(Self.roomSuggestions.filter { n in !scannedHere(n) && !controller.existingRoomNames.contains { HouseProject.roomKey($0) == HouseProject.roomKey(n) } }, id: \.self) { name in
            Button(name) { controller.selectedRoomID = nil; controller.roomName = name }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(controller.roomName == name ? .accentColor : .secondary)
          }
        }
      }
      if controller.selectedRoomID != nil {
        Text("重新扫描：这将成为 \(controller.roomName) 的当前扫描（旧扫描会保留在历史记录中）。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Toggle("高分辨率自动拍照", isOn: $controller.highResolutionPhotos)
        .font(.subheadline)
      Text("普通照片使用相机帧，扫描更轻量。高分辨率照片会增加处理负担，且在手机温度较低时每 3 秒最多请求一张。快门始终会保存一张普通照片。")
        .font(.caption).foregroundStyle(.secondary)
      Button {
        controller.startRoom()
      } label: {
        Label(controller.canStartRoom ? "Scan \(controller.roomName)" : "请先命名房间以开始", systemImage: "viewfinder")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!controller.canStartRoom)
      if !controller.rooms.isEmpty {
        HStack {
          Button("重做上一个房间", role: .destructive, action: controller.discardLastRoom)
          Spacer()
          Button("结束会话") { Task { await controller.finishSession() } }
            .buttonStyle(.bordered)
        }
      }
    }
  }

  private func scannedHere(_ name: String) -> Bool {
    controller.rooms.contains { HouseProject.roomKey($0.name) == HouseProject.roomKey(name) }
  }

  private var pausedPanel: some View {
    panel {
      Label("已暂停", systemImage: "pause.circle.fill").font(.headline)
      Text("暂停期间没有照片、深度或覆盖数据。追踪仍在运行：请让摄像头始终对准房间（不要对着地面或口袋），以免丢失位置。")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button {
        controller.resume()
      } label: {
        Label("继续 \(controller.roomName)", systemImage: "play.fill").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Button("完成房间并保存已获取的内容", action: controller.finishRoom)
        .buttonStyle(.bordered)
    }
  }

  private var roomList: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(controller.rooms) { room in
        HStack {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text(room.name)
          Spacer()
          if let pc = room.photographedPercent {
            Text("\(pc)% 拍照细节").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(pc >= 85 ? .green : .orange)
          }
          Text("\(room.walls)墙 \(room.doors + room.openings)门 \(room.windows)窗 \(room.objects)物")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var scanControls: some View {
    VStack(spacing: 10) {
      if controller.captureReady {
        tip(controller.quality.ready ? controller.quality.message : (controller.instruction ?? controller.quality.message))
        if controller.coveragePlateau && !controller.quality.ready {
          tip("Photo detail isn't improving much. You can save and review what you have; you don't need to keep circling.")
        }
        if controller.captureBudget.constrained { Text("正在降低后台采集频率，以保持扫描流畅。").font(.caption).foregroundStyle(.white) }
      }
      HStack(spacing: 14) {
        Legend()
        Button(action: controller.pause) {
          Image(systemName: "pause.fill")
        }
        .buttonStyle(.bordered)
        shutter
        Button(controller.quality.ready ? "Finish room ✓" : "Save room", action: controller.finishRoom)
          .buttonStyle(.borderedProminent)
          .tint(controller.quality.ready ? .green : .accentColor)
          .controlSize(.large)
      }
    }
    .padding(.horizontal)
  }

  private var shutter: some View {
    Button(action: controller.takePhoto) {
      Image(systemName: "camera.fill")
        .font(.title2)
        .frame(width: 60, height: 60)
        .background(.white, in: Circle())
        .foregroundStyle(.black)
    }
    .disabled(!controller.canTakePhoto)
    .opacity(controller.canTakePhoto ? 1 : 0.4)
    .accessibilityLabel("拍摄参考照片")
  }

  private func tip(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .multilineTextAlignment(.center)
      .padding(8)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
  }

  private var done: some View {
    panel {
      Label("已保存", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
      roomList
      HStack(spacing: 8) {
        AlignmentBadge(alignment: controller.alignment)
        Text(controller.mapSummary ?? "地图未保存").font(.caption).foregroundStyle(.secondary)
      }
      Text("随时回来点击**扫描一个房间**，或打开已保存的房间并选择**从该房间继续扫描**。在房屋主界面分享（通过 AirDrop 把 .zip 发给你的 Mac）。")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("关闭", action: onClose).buttonStyle(.borderedProminent)
    }
  }

  private func status(_ text: String) -> some View {
    panel {
      HStack(spacing: 12) {
        ProgressView()
        Text(text)
      }
    }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .padding()
      .frame(maxWidth: 500)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
      .padding(.horizontal)
  }
}

/// Continue: find your place in the zone's saved map
private struct RelocalizationPanel: View {
  @ObservedObject var controller: CaptureController

  private var r: CaptureController.Relocalization { controller.reloc }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.headline)
        Spacer()
        if r.seconds > 0 { Text("\(r.seconds) 秒").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
      }
      Text(message).font(.subheadline)
      if r.stage == .checking {
        ProgressView(value: Double(r.progress))
          .tint(.green)
        if let c = r.check, c.known > 0 {
          Text("你看到的墙体中有 \(Int((c.wallKnown > 0 ? c.wallFraction : c.inlierFraction) * 100))% 吻合\(c.median.map { String(format: " · 偏差 %.1f 厘米", $0 * 100) } ?? "")")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          if c.needsCorner {
            Text("现在横向平移扫过墙角、门框或家具：单独一面平墙无法判断它是否发生了侧向偏移。")
              .font(.caption.weight(.semibold))
          } else if c.wallKnown < 100 {
            Text("对准你之前扫描过的墙面和家具（不只是地面）。")
              .font(.caption.weight(.semibold))
          }
        }
      }
      Text(r.tracking + " · " + r.reference).font(.caption).foregroundStyle(.secondary)
      if !controller.landmarks.isEmpty, r.stage == .searching || r.stage == .mismatch {
        Text("你之前扫描过的位置：").font(.caption.weight(.semibold))
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(controller.landmarks, id: \.self) { LandmarkThumb(url: $0) }
          }
        }
      }
      if r.seconds >= 20 || r.timedOut || r.stage == .mismatch {
        tips
      }
      if r.timedOut, r.stage != .mismatch {
        Text("仍然无法确定你的位置。").font(.subheadline.weight(.semibold))
        HStack {
          Button("继续尝试", action: controller.keepTrying).buttonStyle(.bordered)
          Spacer()
          Button("开始一次新的扫描", action: controller.startUnaligned).buttonStyle(.borderedProminent)
        }
      } else {
        HStack {
          if r.stage == .mismatch {
            Button("重试", action: controller.retryRelocalization).buttonStyle(.borderedProminent)
          }
          Spacer()
          if r.seconds >= 20 || r.stage == .mismatch || isFailed {
            Button("开始一次新的扫描", action: controller.startUnaligned).buttonStyle(.bordered)
          }
        }
      }
    }
    .padding()
    .frame(maxWidth: 500)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    .padding(.horizontal)
  }

  private var isFailed: Bool {
    if case .failed = r.stage { return true }
    return false
  }

  private var title: String {
    switch r.stage {
    case .loadingMap: "正在加载 \(controller.zoneName)…"
    case .searching: "在 \(controller.zoneName) 中继续"
    case .checking: "已找到：正在检查贴合度"
    case .mismatch: "无法对齐"
    case .done: "已对齐"
    case .failed: "无法从已保存的地图继续"
    }
  }

  private var message: String {
    switch r.stage {
    case .loadingMap: "Reading the saved map."
    case .searching: "Point at an area you already scanned and move slowly. When the phone recognizes it, your earlier scan appears in green."
    case .checking: "Hold on the area you scanned before. The green should sit right on the walls and furniture."
    case .mismatch: "The phone thinks it knows this place, but the green doesn't sit on the real surfaces. Try again from a spot with lots of detail, or start unaligned."
    case .done: ""
    case .failed(let m): m + " You can still scan: the session gets its own frame. Use Connect room afterward to align it with another room."
    }
  }

  private var tips: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("• 打开与上次相同的灯光。")
      Text("• 站在你之前扫描过的位置，比如门口或有家具的墙角，退后 1–2 米，缓慢平移。")
      Text("• 光秃的墙面和地面不行；请对准架子、画作、门框。")
      Text("• 上次之后东西移动了？请对准没有移动的物品。")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

/// One earlier photo, loaded off main
private struct LandmarkThumb: View {
  let url: URL
  @State private var image: CGImage?
  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else {
        Color.gray.opacity(0.3)
      }
    }
    .frame(width: 84, height: 112)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task {
      let u = url
      image = await Task.detached(priority: .utility) { PriorPhotos.thumbnail(u) }.value
    }
  }
}

/// "Relocalized ±2 cm" / "Unaligned" / "First in area"
struct AlignmentBadge: View {
  var alignment: HouseProject.Alignment
  var body: some View {
    let (text, color): (String, Color) = switch alignment.method {
    case "first": ("New scan", .blue)
    case "relocalized": (alignment.residualMeters.map { String(format: "Matched ±%.1f cm", $0 * 100) } ?? "Matched", .green)
    case "unaligned": ("Not connected yet", .orange)
    case "manual", "icp": ("Connected", .teal)
    default: (alignment.method, .gray)
    }
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.25), in: Capsule())
      .foregroundStyle(color)
  }
}

/// ARKit's world-mapping status: green once the map is good enough to save
private struct MapStatusDot: View {
  var status: ARFrame.WorldMappingStatus
  var body: some View {
    let (text, color): (String, Color) = switch status {
    case .mapped: ("map", .green)
    case .extending: ("map", .yellow)
    case .limited: ("map", .orange)
    default: ("map", .gray)
    }
    HStack(spacing: 3) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(text).font(.caption2)
    }
  }
}

/// Percent photographed, as a ring
struct CoverageRing: View {
  var percent: Int
  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.25), lineWidth: 5)
      Circle()
        .trim(from: 0, to: CGFloat(min(100, percent)) / 100)
        .stroke(percent >= 85 ? Color.green : percent >= 50 ? .orange : .red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.4), value: percent)
      Text("\(percent)%").font(.caption2.monospacedDigit().weight(.bold))
    }
  }
}

private struct Legend: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach([(Color.red, "needs photos"), (.green, "captured")], id: \.1) { color, label in
        HStack(spacing: 4) {
          Circle().fill(color).frame(width: 7, height: 7)
          Text(label).font(.system(size: 9))
        }
      }
    }
    .padding(6)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

/// Hosts the scan's ARSCNView (camera + coverage mesh + RoomPlan outlines)
struct ARViewContainer: UIViewRepresentable {
  let view: ARSCNView
  func makeUIView(context: Context) -> ARSCNView { view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
