import SwiftUI

struct FieldworkRoomScreen: View {
  let houseID: String
  let roomID: String
  let generation: Int
  let onCapture: (String, String?, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var house: HouseProject?
  @State private var manifests: [String: Manifest] = [:]
  @State private var sharing: URL?
  @State private var busy = false
  @State private var error: String?
  @State private var renaming = false
  @State private var name = ""
  @State private var deleting = false
  @State private var deletingScan: HouseProject.RoomRef?
  @State private var historyOpen = false
  private var room: HouseProject.Room? { house?.rooms.first { $0.id == roomID } }

  var body: some View {
    ScrollView {
      if let house, let room {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 10) {
            FieldworkEyebrow(text: "Saved room")
            Text(room.name).font(.largeTitle.weight(.bold)).tracking(-1)
            if let active = room.active {
              Text("已扫描 " + active.capturedAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
            }
          }
          if let active = room.active, let session = house.session(active.session) {
            FieldworkRoomPreview(source: source(house, room, session, active))
              .id("\(active.session)/\(active.index)")
            let record = manifests[active.session]?.rooms.first { $0.index == active.index }
            HStack(alignment: .top, spacing: 28) {
              metric(record?.photographedPercent.map { "\($0)%" } ?? "—", label: "拍照细节")
              Rectangle().fill(Fieldwork.rule).frame(width: 0.5, height: 42)
              metric(record?.detailPhotos.map(String.init) ?? "—", label: "细节照片")
              Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
              Button { share(house.bundle(for: session), active.index, room.name) } label: {
                Label(busy ? "Preparing room…" : "Share room", systemImage: "square.and.arrow.up")
              }.buttonStyle(FieldworkButtonStyle()).disabled(busy)
              Button { onCapture(house.id, room.zone, nil, room.id) } label: {
                Label("继续扫描", systemImage: "viewfinder")
              }.buttonStyle(FieldworkButtonStyle(filled: false)).disabled(!CaptureController.isSupported || busy)
              Text("从这个房间开始，让手机识别周围环境。")
                .font(.caption).foregroundStyle(Fieldwork.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            FieldworkRule()
            DisclosureGroup(isExpanded: $historyOpen) {
              history(house, room)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 4) {
                  Text("扫描历史").foregroundStyle(Fieldwork.ink)
                  Text("\(room.history.count) 条已保存的扫描")
                    .font(.caption).foregroundStyle(Fieldwork.secondary)
                }
              } icon: { Image(systemName: "clock").foregroundStyle(Fieldwork.secondary).frame(width: 28) }
            }.padding(.vertical, 4)
            FieldworkRule()
            NavigationLink {
              RoomConnection(house: house, source: room, onSave: reload)
            } label: { actionRow("连接房间", subtitle: "与另一次扫描匹配同一个门洞", icon: "link") }
            FieldworkRule()
            Text("拍照细节衡量的是已观测表面上有效拍照的覆盖程度，并非房间被扫描的百分比。")
              .font(.caption).foregroundStyle(Fieldwork.secondary)
          } else {
            ContentUnavailableView("没有正在进行的扫描", systemImage: "cube.transparent", description: Text("扫描此房间以生成它的首个预览。"))
            Button("扫描此房间") { onCapture(house.id, room.zone, nil, room.id) }
              .buttonStyle(FieldworkButtonStyle()).disabled(!CaptureController.isSupported)
          }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 32)
      } else { ProgressView().padding(40) }
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { FieldworkEyebrow(text: house?.name ?? "3D 实景建模") }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("重命名房间", systemImage: "pencil") { name = room?.name ?? ""; renaming = true }
          Button("删除房间", systemImage: "trash", role: .destructive) { deleting = true }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("房间选项")
      }
    }
    .onAppear(perform: reload).onChange(of: generation) { _, _ in reload() }
    .sheet(item: $sharing) { ShareSheet(items: [$0]) }
    .alert("重命名房间", isPresented: $renaming) {
      TextField("房间名称", text: $name)
      Button("保存") { perform { try HouseProject.renameRoom(houseID: houseID, roomID: roomID, name: name) } }
      Button("取消", role: .cancel) {}
    }
    .confirmationDialog("将房间移到“最近删除”？", isPresented: $deleting, titleVisibility: .visible) {
      Button("删除房间", role: .destructive) {
        perform { try HouseProject.moveRoomToTrash(houseID: houseID, roomID: roomID) }
      }
    } message: { Text("你可以从房屋的“最近删除”分区恢复此房间及其扫描。") }
    .confirmationDialog("将此扫描移到“最近删除”？", isPresented: Binding(get: { deletingScan != nil }, set: { if !$0 { deletingScan = nil } }), titleVisibility: .visible) {
      Button("删除扫描", role: .destructive) {
        if let ref = deletingScan { perform { try HouseProject.deleteScan(houseID: houseID, roomID: roomID, ref: ref) } }
        deletingScan = nil
      }
    }
    .alert("出现了问题", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("好") { error = nil }
    } message: { Text(error ?? "") }
  }

  private func metric(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.title2.bold()).monospacedDigit()
      Text(label).font(.system(.caption, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
    }
  }
  private func actionRow(_ title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).frame(width: 28).font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body)
        Text(subtitle).font(.caption).foregroundStyle(Fieldwork.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(Fieldwork.secondary)
    }.foregroundStyle(Fieldwork.ink).frame(minHeight: 48).contentShape(Rectangle())
  }
  private func source(_ house: HouseProject, _ room: HouseProject.Room, _ session: HouseProject.Session, _ ref: HouseProject.RoomRef) -> PreviewSource {
    var source = PreviewSource.session(house, session)
    source.title = room.name
    source.rooms = source.rooms.filter { $0.index == ref.index }
    return source
  }
  private func history(_ house: HouseProject, _ room: HouseProject.Room) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(room.history.reversed().enumerated()), id: \.offset) { _, ref in
        VStack(alignment: .leading, spacing: 10) {
          Text(ref.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
          if ref == room.active { Label("当前扫描", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Fieldwork.orange) }
          ViewThatFits(in: .horizontal) {
            HStack { versionActions(house, room, ref) }
            VStack(alignment: .leading) { versionActions(house, room, ref) }
          }
        }
        FieldworkRule()
      }
    }.padding(.top, 18)
  }
  @ViewBuilder private func versionActions(_ house: HouseProject, _ room: HouseProject.Room, _ ref: HouseProject.RoomRef) -> some View {
    if let session = house.session(ref.session) {
      NavigationLink("查看 / 对比") { ScanVersionReview(house: house, room: room, ref: ref, session: session) }
        .buttonStyle(.bordered)
    }
    if ref != room.active {
      Button("使用此扫描") { perform { _ = try HouseProject.modify(houseID) { $0.setActive(room: roomID, ref) } } }.buttonStyle(.bordered)
    }
    Button(role: .destructive) { deletingScan = ref } label: { Image(systemName: "trash").frame(minWidth: 32, minHeight: 32) }
      .accessibilityLabel("删除来自 \(ref.capturedAt.formatted()) 的扫描")
  }
  private func reload() {
    do {
      let h = try HouseProject.load(id: houseID)
      guard h.rooms.contains(where: { $0.id == roomID }) else { dismiss(); return }
      house = h
      Task {
        let records = await Task.detached(priority: .utility) { h.sessions.reduce(into: [String: Manifest]()) { $0[$1.id] = h.bundle(for: $1).manifest } }.value
        manifests = records
      }
    } catch { self.error = error.localizedDescription }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); reload() } catch { self.error = error.localizedDescription }
  }
  private func share(_ bundle: ScanBundle, _ index: Int, _ name: String) {
    busy = true
    Task {
      let result = await Task.detached(priority: .userInitiated) { Result { try bundle.zippedRoom(index: index, name: name) } }.value
      busy = false
      switch result {
      case .success(let url): sharing = url
      case .failure(let err): error = err.localizedDescription
      }
    }
  }
}

private struct FieldworkRoomPreview: View {
  @StateObject private var model: PreviewModel
  @State private var coverage = false
  @State private var expanded = false
  init(source: PreviewSource) { _model = StateObject(wrappedValue: PreviewModel(source: source)) }
  var body: some View {
    VStack(spacing: 12) {
      Picker("预览样式", selection: $coverage) {
        Text("3D").tag(false)
        Text("拍照细节").tag(true)
      }.pickerStyle(.segmented).disabled(model.phase != .ready || !model.styles.contains(.coverage))
      ZStack {
        if !expanded { PreviewSceneView(scene: model.scene) }
        switch model.phase {
        case .loading: ProgressView(model.loadStage).font(.caption).padding().background(Fieldwork.paper.opacity(0.95))
        case .empty(let message): ContentUnavailableView("暂无可预览内容", systemImage: "cube.transparent", description: Text(message))
        case .ready: EmptyView()
        }
      }
      .frame(height: 280).clipped()
      .overlay(FieldworkCorners().stroke(Fieldwork.orange, lineWidth: 1.5).allowsHitTesting(false))
      HStack {
        Text(coverage ? "绿色表面已拍到有用的照片" : "拖动旋转 · 双指缩放")
          .font(.caption).foregroundStyle(Fieldwork.secondary)
        Spacer()
        Button {
          model.scene.scene.background.contents = UIColor(white: 0.07, alpha: 1)
          model.scene.view.backgroundColor = .black
          expanded = true
        } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
          .accessibilityLabel("打开全屏查看器")
      }
    }
    .onAppear { paperBackground(); model.start() }
    .onDisappear { if !expanded { model.cancelBake() } }
    .onChange(of: coverage) { _, value in model.setStyle(value ? .coverage : .photo) }
    .fullScreenCover(isPresented: $expanded, onDismiss: {
      paperBackground()
      coverage = model.style == .coverage
      if !coverage, model.styles.contains(.photo) { model.setStyle(.photo) }
    }) { PreviewScreen(model: model) }
  }
  private func paperBackground() {
    model.scene.scene.background.contents = Fieldwork.uiPaper
    model.scene.view.backgroundColor = Fieldwork.uiPaper
  }
}
