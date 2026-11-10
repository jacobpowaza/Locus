import MapKit
import SwiftUI

struct SpeedZonesSection: View {
    @Binding var zones: [SpeedZone]?
    let plan: RunPlan?
    let unit: SpeedUnit
    @State private var editing: SpeedZone?

    var body: some View {
        Section {
            ForEach(Array((zones ?? []).enumerated()), id: \.element.id) { index, zone in
                Button {
                    editing = zone
                } label: {
                    LabeledContent("Zone \(index + 1)", value: RunFormat(unit: unit).speed(zone.speed))
                }
            }
            .onDelete { offsets in
                var updated = zones ?? []
                updated.remove(atOffsets: offsets)
                zones = updated
            }
            Button {
                editing = SpeedZone(vertices: [], speed: SpeedUnit.mph.toMetersPerSecond(25))
            } label: {
                Label("Draw Speed Zone", systemImage: "pencil.and.outline")
            }
            .disabled(plan == nil || (zones?.count ?? 0) >= 20)
        } header: {
            Text("Custom Speed Zones")
        } footer: {
            Text("Zone targets override the selected speed inside the outline. Overlapping zones use the lower target.")
        }
        .sheet(item: $editing) { zone in
            SpeedZoneEditor(zone: zone, plan: plan, otherZones: (zones ?? []).filter { $0.id != zone.id }, unit: unit) { edited in
                var updated = zones ?? []
                if let index = updated.firstIndex(where: { $0.id == edited.id }) {
                    updated[index] = edited
                } else {
                    updated.append(edited)
                }
                zones = updated
            }
        }
    }
}

private struct SpeedZoneEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var zone: SpeedZone
    let plan: RunPlan?
    let otherZones: [SpeedZone]
    let unit: SpeedUnit
    let onSave: (SpeedZone) -> Void

    private var displaySpeed: Binding<Double> {
        Binding(get: { unit.fromMetersPerSecond(zone.speed).rounded() },
                set: { zone.speed = unit.toMetersPerSecond($0) })
    }

    private var initialPosition: MapCameraPosition {
        let points = zone.vertices.isEmpty
            ? (plan?.segments ?? []).flatMap { segment -> [GeoPoint] in
                if case .drive(let leg) = segment.kind { return leg.profile.polyline.points }
                return []
            }
            : zone.vertices
        guard !points.isEmpty else { return .automatic }
        let coordinates = points.map(\.coordinate)
        let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let padding = max(350, max(rect.width, rect.height) * 0.12)
        return .rect(rect.insetBy(dx: -padding, dy: -padding))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(initialPosition: initialPosition) {
                        if let plan {
                            ForEach(plan.segments) { segment in
                                if case .drive(let leg) = segment.kind {
                                    MapPolyline(coordinates: leg.profile.polyline.points.map(\.coordinate))
                                        .stroke(.blue, lineWidth: 4)
                                }
                            }
                        }
                        ForEach(otherZones.filter(\.isValid)) { other in
                            MapPolygon(coordinates: other.vertices.map(\.coordinate))
                                .foregroundStyle(.orange.opacity(0.18))
                        }
                        if zone.vertices.count >= 3 {
                            MapPolygon(coordinates: zone.vertices.map(\.coordinate))
                                .foregroundStyle(.orange.opacity(0.30))
                        }
                        if zone.vertices.count >= 2 {
                            let outline = zone.vertices + (zone.vertices.count >= 3 ? [zone.vertices[0]] : [])
                            MapPolyline(coordinates: outline.map(\.coordinate)).stroke(.orange, lineWidth: 3)
                        }
                        ForEach(zone.vertices.indices, id: \.self) { index in
                            Annotation("Corner \(index + 1)", coordinate: zone.vertices[index].coordinate) {
                                Circle().fill(.orange)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                    .frame(width: 12, height: 12)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .onTapGesture { location in
                        guard zone.vertices.count < SpeedZone.maximumVertices,
                              let coordinate = proxy.convert(location, from: .local) else { return }
                        let point = GeoPoint(coordinate)
                        guard point.isValid, !zone.vertices.contains(point) else { return }
                        zone.vertices.append(point)
                    }
                    .mapControls { MapCompass() }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tap the map to outline the area with at least three corners.")
                        .font(.subheadline)
                    HStack {
                        Button("Undo Corner", systemImage: "arrow.uturn.backward") { zone.vertices.removeLast() }
                        Spacer()
                        Button("Clear Outline") { zone.vertices.removeAll() }
                    }
                    .disabled(zone.vertices.isEmpty)
                    LabeledContent("Target Speed", value: RunFormat(unit: unit).speed(zone.speed))
                    Slider(value: displaySpeed, in: 2...(unit == .mph ? 120 : 190), step: 1)
                        .accessibilityLabel("Target Speed")
                        .accessibilityValue(RunFormat(unit: unit).speed(zone.speed))
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Speed Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(zone)
                        dismiss()
                    }
                    .disabled(!zone.isValid)
                }
            }
        }
    }
}
