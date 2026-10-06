import SwiftUI
import MapKit
import ServiceManagement

/// What a place reminder is being set on: a whole list, or one task in it.
/// The endpoints differ by one path segment; the sheet is otherwise the same.
enum MacPlaceTarget: Identifiable {
    case list(TodoList)
    case item(listId: String, todo: Todo)

    var id: String {
        switch self {
        case .list(let list): "list-\(list.id)"
        case .item(_, let todo): "item-\(todo.id)"
        }
    }

    var subject: String {
        switch self {
        case .list(let list): list.label
        case .item(_, let todo): todo.title
        }
    }

    var hasLocation: Bool {
        switch self {
        case .list(let list): list.hasLocation
        case .item(_, let todo): todo.hasLocation
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        let pair: (Double?, Double?)
        switch self {
        case .list(let list): pair = (list.locationLat, list.locationLng)
        case .item(_, let todo): pair = (todo.locationLat, todo.locationLng)
        }
        guard let lat = pair.0, let lng = pair.1 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var radius: Double? {
        switch self {
        case .list(let list): list.locationRadius
        case .item(_, let todo): todo.locationRadius
        }
    }

    var locationName: String? {
        switch self {
        case .list(let list): list.locationName
        case .item(_, let todo): todo.locationName
        }
    }

    var trigger: GeofenceTrigger {
        switch self {
        case .list(let list): list.trigger
        case .item(_, let todo): todo.trigger
        }
    }
}

/// Choosing a place for a reminder: search, or click the map.
///
/// A sheet over the window rather than a full screen as on iOS: the map is
/// the thing being chosen, and a Mac sheet is big enough to hold it beside the
/// controls without anything covering anything.
struct MacPlacePickerSheet: View {
    let target: MacPlaceTarget

    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss

    /// What to say once the place is saved — the Mac's version of the iOS
    /// "Always" upgrade. A Mac has no While Using / Always split: once location
    /// is allowed, a place is watched for as long as twodos is running. So the
    /// two things that can still stop a reminder are location being off, and
    /// twodos not running — which "Open at Login" fixes.
    private enum FollowUp: Identifiable {
        case locationOff, openAtLogin
        var id: Self { self }
    }
    @State private var followUp: FollowUp?
    /// Offered once; after that it lives in Settings → General.
    @AppStorage("mac.loginItemOffered") private var loginItemOffered = false

    @State private var camera: MapCameraPosition = .automatic
    @State private var pin: CLLocationCoordinate2D?
    @State private var placeName = ""
    @State private var radius: Double = 200
    @State private var trigger: GeofenceTrigger = .arrive
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let radiusOptions: [Double] = [100, 200, 500, 1_000, 2_000]

    init(target: MacPlaceTarget) {
        self.target = target
        _pin = State(initialValue: target.coordinate)
        _placeName = State(initialValue: target.locationName ?? "")
        _radius = State(initialValue: target.radius ?? 200)
        _trigger = State(initialValue: target.trigger)
        if let coordinate = target.coordinate {
            let span = (target.radius ?? 200) * 6
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: coordinate, latitudinalMeters: span, longitudinalMeters: span
            )))
        }
    }

    /// Kept for the inspector's existing call site.
    init(list: TodoList) {
        self.init(target: .list(list))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Place reminder").font(.title2.weight(.semibold))
                Text(target.subject).foregroundStyle(.secondary).lineLimit(1)
            }

            if let errorMessage {
                MacBanner(kind: .error, title: errorMessage)
            }

            HStack(spacing: 8) {
                TextField("Search for a place", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            if !results.isEmpty {
                List(results, id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Place")
                            if let address = item.address?.shortAddress {
                                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 130)
                .listStyle(.bordered)
            }

            MapReader { proxy in
                Map(position: $camera) {
                    if let pin {
                        Marker(placeName.isEmpty ? "Here" : placeName, coordinate: pin)
                        MapCircle(center: pin, radius: radius)
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        pin = coordinate
                    }
                }
            }
            .frame(minHeight: 260)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if pin == nil {
                    Text("Search, or click the map to drop a pin.")
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                        .padding(8)
                }
            }

            Form {
                TextField("Name", text: $placeName, prompt: Text("e.g. Supermarket"))
                Picker("Remind me", selection: $trigger) {
                    ForEach(GeofenceTrigger.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Within", selection: $radius) {
                    ForEach(Self.radiusOptions, id: \.self) { Text(Format.distance(metres: $0)).tag($0) }
                }
            }
            .formStyle(.columns)

            HStack {
                if target.hasLocation {
                    Button("Remove Place", role: .destructive) { Task { await clear() } }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin == nil || isSaving)
            }
        }
        .padding(20)
        .frame(width: 560, height: results.isEmpty ? 600 : 740)
        .alert(item: $followUp) { followUp in
            switch followUp {
            case .locationOff:
                Alert(
                    title: Text("Location is off for twodos"),
                    message: Text("The place is saved, but its reminder can't fire until you allow location for twodos in System Settings."),
                    primaryButton: .default(Text("Open System Settings")) {
                        MacLocationSettings.open()
                        dismiss()
                    },
                    secondaryButton: .cancel(Text("Not Now")) { dismiss() }
                )
            case .openAtLogin:
                Alert(
                    title: Text("Keep reminding you after you log in?"),
                    message: Text("Place reminders work while twodos is running — closing the window keeps it running. Open it at login so a restart doesn't stop them."),
                    primaryButton: .default(Text("Open at Login")) {
                        try? SMAppService.mainApp.register()
                        dismiss()
                    },
                    secondaryButton: .cancel(Text("Not Now")) { dismiss() }
                )
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            if results.isEmpty { errorMessage = String(localized: "Nothing found for “\(text)”.") }
            else { errorMessage = nil }
        } catch {
            errorMessage = String(localized: "Search isn't available right now. Click the map to drop a pin instead.")
        }
    }

    private func select(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        pin = coordinate
        if placeName.trimmingCharacters(in: .whitespaces).isEmpty || results.contains(where: { $0.name == placeName }) {
            placeName = item.name ?? ""
        }
        camera = .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: radius * 6, longitudinalMeters: radius * 6
        ))
        results = []
    }

    private func save() {
        guard let pin else { return }
        isSaving = true
        errorMessage = nil
        let name = placeName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isSaving = false }
            do {
                switch target {
                case .list(let list):
                    try await store.setListLocation(
                        listId: list.id, name: name,
                        latitude: pin.latitude, longitude: pin.longitude,
                        radius: radius, trigger: trigger
                    )
                case .item(let listId, let todo):
                    try await store.setItemLocation(
                        listId: listId, todoId: todo.id, name: name,
                        latitude: pin.latitude, longitude: pin.longitude,
                        radius: radius, trigger: trigger
                    )
                }
                await afterSaving()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// Asks for location the first time a place is saved — the moment there is
    /// something to justify the prompt — then says what else, if anything,
    /// stands between this place and its reminder.
    private func afterSaving() async {
        if location.authorization == .notDetermined {
            location.requestWhenInUse()
            // Give the system prompt its answer before deciding what to say.
            for _ in 0..<60 where location.authorization == .notDetermined {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if location.isDenied {
            followUp = .locationOff
        } else if !loginItemOffered, SMAppService.mainApp.status != .enabled {
            loginItemOffered = true
            followUp = .openAtLogin
        } else {
            dismiss()
        }
    }

    private func clear() async {
        switch target {
        case .list(let list): await store.clearListLocation(listId: list.id)
        case .item(let listId, let todo): await store.clearItemLocation(listId: listId, todoId: todo.id)
        }
        dismiss()
    }
}
