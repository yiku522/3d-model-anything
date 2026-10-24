import SwiftUI
import simd

struct RoomDoor: Identifiable {
  let id: String
  let width: Float
  let transform: simd_float4x4
  static func load(house: HouseProject, room: HouseProject.Room) -> [RoomDoor] {
    guard let ref = room.active, let session = house.session(ref.session),
          let data = try? Data(contentsOf: house.bundle(for: session).file("rooms/room-\(ref.index).json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    return (["doors", "openings"].flatMap { json[$0] as? [[String: Any]] ?? [] }).compactMap { d in
      guard let t = d["transform"] as? [Float], t.count == 16,
            let dimensions = d["dimensions"] as? [Float], let width = dimensions.first,
            let id = d["identifier"] as? String else { return nil }
      return .init(id: id, width: width, transform: simd_float4x4(columnMajor: t))
    }
  }
}

/// Doorway correspondence is user-verified; never silently treat separate maps as aligned.
struct RoomConnection: View {
  let house: HouseProject
  let source: HouseProject.Room
  let onSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var targetID = ""
  @State private var sourceDoorID = ""
  @State private var targetDoorID = ""
  @State private var flip = true
  @State private var previewing = false
  @State private var checked = false
  @State private var error: String?
  private var target: HouseProject.Room? { house.rooms.first { $0.id == targetID } }
  private var sourceDoors: [RoomDoor] { RoomDoor.load(house: house, room: source) }
  private var targetDoors: [RoomDoor] { target.map { RoomDoor.load(house: house, room: $0) } ?? [] }
  private var candidate: HouseProject? {
    guard let target, let sr = source.active, let tr = target.active,
          let ss = house.session(sr.session), let ts = house.session(tr.session), ss.zone != ts.zone,
          let sd = sourceDoors.first(where: { $0.id == sourceDoorID }),
          let td = targetDoors.first(where: { $0.id == targetDoorID }), abs(sd.width-td.width) < 0.2,
          let zi = house.zones.firstIndex(where: { $0.id == ss.zone }), house.zone(ts.zone)?.aligned == true,
          ts.alignment.method != "unaligned", ss.alignment.method != "unaligned" else { return nil }
    let turn = simd_float4x4(simd_quatf(angle: flip ? .pi : 0, axis: SIMD3(0,1,0)))
    let transform = house.toHouse(ts) * td.transform * turn * sd.transform.inverse * simd_float4x4(columnMajor: ss.alignment.toZone).inverse
    var result = house
    result.zones[zi].toHouse = transform.columnMajor
    result.zones[zi].aligned = true
    return result
  }
  var body: some View {
    Form {
      Section {
        Text("在两个房间中匹配同一个门洞。如果某次扫描没有拍到它，请从已保存的房间继续扫描，并把门洞两侧都拍进去。")
        Picker("将 \(source.name) 连接到", selection: $targetID) {
          Text("选择房间").tag("")
          ForEach(house.rooms.filter { $0.id != source.id }) { Text($0.name).tag($0.id) }
        }
        DoorwayMap(house: house, room: source, doors: sourceDoors, selected: $sourceDoorID)
        doorPicker("\(source.name) 中的门洞", doors: sourceDoors, selection: $sourceDoorID)
        if let target { DoorwayMap(house: house, room: target, doors: targetDoors, selected: $targetDoorID) }
        doorPicker("另一个房间中的门洞", doors: targetDoors, selection: $targetDoorID)
        Text("在每个房间的平面图上点击对应的门洞编号。门洞宽度有助于区分相似的开口。").font(.caption)
        Toggle("房间位于门洞的两侧", isOn: $flip)
        if target?.zone == source.zone { Text("这些房间已经共享同一个追踪坐标系。") }
        if let target, house.zone(target.zone)?.aligned != true { Text("选择房屋中已摆放好的某个房间作为参考。") }
        if sourceDoors.isEmpty || (target != nil && targetDoors.isEmpty) { Text("缺少一个门洞。请先扫描一条连通的走廊或门洞，再连接这两个房间。") }
        if candidate == nil { Text("在分别扫描、且已完成追踪的两个房间中，选择宽度相差不超过 20 厘米的门洞。").font(.caption) }
        Button("预览连接") { previewing = true; checked = true }.disabled(candidate == nil)
        Text("检查墙面、地面高度，以及每个房间占据门洞的哪一侧。这是手动摆放，不是自动匹配。").font(.caption)
        let companions = house.rooms.filter { $0.zone == source.zone && $0.id != source.id }.map(\.name)
        if !companions.isEmpty { Text("随此房间一起移动：" + companions.joined(separator: ", ")).font(.caption) }
        Button("保存连接") {
          guard let candidate, let ref = source.active, let session = house.session(ref.session), let zone = candidate.zone(session.zone) else { return }
          do {
            try HouseProject.modify(house.id) { h in
              guard let i = h.zones.firstIndex(where: { $0.id == zone.id }) else { return }
              h.zones[i].toHouse = zone.toHouse; h.zones[i].aligned = true
            }
            onSave(); dismiss()
          } catch { self.error = error.localizedDescription }
        }.disabled(!checked || candidate == nil)
        if let error { Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle("连接房间")
    .onChange(of: targetID) { _, _ in targetDoorID = ""; checked = false }
    .onChange(of: sourceDoorID) { _, _ in checked = false }
    .onChange(of: targetDoorID) { _, _ in checked = false }
    .onChange(of: flip) { _, _ in checked = false }
    .sheet(isPresented: $previewing) {
      if let candidate { NavigationStack { HouseViewer(house: candidate).toolbar { Button("完成") { previewing = false } } } }
    }
  }
  private func doorPicker(_ title: String, doors: [RoomDoor], selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("选择门洞").tag("")
      ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
        Text(String(format: "门洞 %d · 宽 %.2f 米", i+1, door.width)).tag(door.id)
      }
    }
  }
}

private struct DoorwayMap: View {
  let house: HouseProject
  let room: HouseProject.Room
  let doors: [RoomDoor]
  @Binding var selected: String
  private var segments: [(SIMD2<Float>, SIMD2<Float>)] {
    guard let ref = room.active, let session = house.session(ref.session),
          let data = try? Data(contentsOf: house.bundle(for: session).file("rooms/room-\(ref.index).json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let walls = json["walls"] as? [[String: Any]] else { return [] }
    return walls.compactMap { w in
      guard let t = w["transform"] as? [Float], t.count == 16, let d = w["dimensions"] as? [Float], let width = d.first else { return nil }
      let center = SIMD2(t[12], t[14]), half = SIMD2(t[0], t[2]) * width / 2
      return (center-half, center+half)
    }
  }
  var body: some View {
    let lines = segments
    let points = lines.flatMap { [$0.0, $0.1] } + doors.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z) }
    let lo = points.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0,$1) }
    let hi = points.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0,$1) }
    GeometryReader { geo in
      let scale = min(Float(geo.size.width-40)/max(hi.x-lo.x,1), Float(geo.size.height-40)/max(hi.y-lo.y,1))
      let project: (SIMD2<Float>) -> CGPoint = { p in CGPoint(x: CGFloat((p.x-(lo.x+hi.x)/2)*scale)+geo.size.width/2, y: CGFloat((p.y-(lo.y+hi.y)/2)*scale)+geo.size.height/2) }
      ZStack {
        Canvas { context, _ in
          for line in lines {
            var path = Path(); path.move(to: project(line.0)); path.addLine(to: project(line.1))
            context.stroke(path, with: .color(.secondary), lineWidth: 3)
          }
        }
        ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
          Button("\(i+1)") { selected = door.id }
            .font(.caption.bold()).frame(width: 28, height: 28)
            .background(selected == door.id ? Color.green : Color.blue, in: Circle()).foregroundStyle(.white)
            .position(project(SIMD2(door.transform.columns.3.x, door.transform.columns.3.z)))
            .buttonStyle(.plain)
        }
      }
    }.frame(height: points.isEmpty ? 0 : 180).accessibilityLabel("\(room.name) 的门洞平面图")
  }
}
