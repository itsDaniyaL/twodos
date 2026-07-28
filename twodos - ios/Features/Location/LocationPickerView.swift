import SwiftUI
import MapKit
import CoreLocation

/// Pinning a place to a list or to a single item, on Apple Maps.
///
/// This is the biggest visual upgrade over the Flutter app, which rendered raw
/// OpenStreetMap tiles and searched Nominatim. Here the map is the real thing:
/// Apple's vector tiles, native place search via `MKLocalSearch`, points of
/// interest the user already recognises, and a Look Around preview so they can
/// confirm they pinned the right doorway rather than the one across the street.
///
/// Location permission is requested only when the user taps "Use my location"
/// or saves a place — never on open, because browsing the map needs no access.

/// What a pin is being attached to.
///
/// The picker was written for lists, but the API has always accepted a location
/// on an individual item too — `PATCH /api/todos/{listId}/items/{todoId}/location`
/// has existed since before either client shipped and neither ever called it.
/// Everything on this screen is identical for both; only the four lines that
/// read and write the location differ, which is what this enum isolates.
enum LocationTarget {
    case list(TodoList)
    /// One item, and the list it belongs to — the endpoint needs both ids.
    case item(listId: String, todo: Todo)

    var listId: String {
        switch self {
        case .list(let list): list.id
        case .item(let listId, _): listId
        }
    }

    /// What the screen is about, shown under the title so a per-item reminder
    /// cannot be mistaken for one covering the whole list.
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
        let lat: Double?
        let lng: Double?
        switch self {
        case .list(let list): (lat, lng) = (list.locationLat, list.locationLng)
        case .item(_, let todo): (lat, lng) = (todo.locationLat, todo.locationLng)
        }
        guard let lat, let lng else { return nil }
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

/// The map screen itself. See ``LocationTarget`` for what it can pin.
struct LocationPickerView: View {
    let target: LocationTarget

    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var pin: CLLocationCoordinate2D?
    @State private var placeName = ""
    @State private var radius: Double = 200
    @State private var trigger: GeofenceTrigger = .arrive

    @State private var searchText = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    @State private var lookAroundScene: MKLookAroundScene?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingAlwaysPrompt = false
    @State private var visibleRegion: MKCoordinateRegion?

    @FocusState private var searchFocused: Bool

    /// Radius options rather than a free slider: the exact metre value does not
    /// matter, and iOS geofences below ~100 m are unreliable anyway.
    private static let radiusOptions: [Double] = [100, 200, 500, 1000, 2000]

    init(list: TodoList) { self.init(target: .list(list)) }

    /// Pins one item rather than the whole list.
    init(listId: String, todo: Todo) { self.init(target: .item(listId: listId, todo: todo)) }

    init(target: LocationTarget) {
        self.target = target
        if let coordinate = target.coordinate {
            let span = (target.radius ?? 200) * 6
            _pin = State(initialValue: coordinate)
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: span,
                longitudinalMeters: span
            )))
        }
        _placeName = State(initialValue: target.locationName ?? "")
        _radius = State(initialValue: target.radius ?? 200)
        _trigger = State(initialValue: target.trigger)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                searchOverlay
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Remind me at a place")
            .navigationSubtitle(target.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if target.hasLocation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Remove", role: .destructive) {
                            Task {
                                await clear()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .alert("Keep reminding me in the background?", isPresented: $showingAlwaysPrompt) {
                Button("Not now", role: .cancel) { dismiss() }
                Button("Allow in background") {
                    location.requestAlways()
                    dismiss()
                }
            } message: {
                Text("twodos can only alert you at \(placeName.isEmpty ? "this place" : placeName) while the app is open. Allowing background location means the reminder finds you even when twodos is closed.")
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let pin {
                    // The geofence itself, drawn to scale so the user can see
                    // exactly how big "200 m" is against real streets.
                    MapCircle(center: pin, radius: radius)
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                        .stroke(Color.accentColor, lineWidth: 2)

                    Annotation(placeName.isEmpty ? "Reminder" : placeName, coordinate: pin) {
                        PinMarker(trigger: trigger)
                    }
                    .annotationTitles(.hidden)
                }

                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange { context in
                visibleRegion = context.region
            }
            .onTapGesture { screenPoint in
                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                setPin(to: coordinate, name: nil)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    /// A pin that shows which direction the reminder fires in.
    private struct PinMarker: View {
        let trigger: GeofenceTrigger
        @State private var appeared = false

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                Image(systemName: trigger.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(appeared ? 1 : 0.4)
            .motion(Motion.delight, value: appeared)
            .onAppear { appeared = true }
            .accessibilityLabel("Reminder location")
        }
    }

    // MARK: - Search

    private var searchOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a place", text: $searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, value in scheduleSearch(value) }
                    .onSubmit { performSearch(searchText) }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }

                Button {
                    Task { await centreOnUser() }
                } label: {
                    Image(systemName: location.isLocating ? "location.circle" : "location.fill")
                        .symbolEffect(.pulse, isActive: location.isLocating)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Use my current location")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)

            if !results.isEmpty {
                searchResults
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .motion(Motion.content, value: results.count)
    }

    private var searchResults: some View {
        GlassCard(radius: Metrics.controlRadius) {
            VStack(spacing: 0) {
                ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { index, item in
                    Button {
                        select(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: item))
                                .font(.system(size: 15))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Unnamed place")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                if let address = shortAddress(for: item) {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if index < min(results.count, 5) - 1 { GlassDivider(inset: 48) }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Bottom controls

    private var controls: some View {
        VStack(spacing: 14) {
            if let errorMessage {
                InlineBanner(kind: .error, title: errorMessage)
            }

            if pin == nil {
                Text("Search for a place, tap the map, or use your current location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                if let scene = lookAroundScene {
                    LookAroundPreview(initialScene: scene)
                        .frame(height: 110)
                        .clipShape(.rect(cornerRadius: Metrics.controlRadius))
                        .accessibilityLabel("Street-level preview of the selected place")
                }

                nameField
                triggerPicker
                radiusPicker

                PrimaryButton(
                    title: target.hasLocation ? "Update reminder" : "Save reminder",
                    icon: "mappin.and.ellipse",
                    isLoading: isSaving
                ) {
                    save()
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.bar)
        .motion(Motion.content, value: pin?.latitude)
        .motion(Motion.content, value: lookAroundScene != nil)
    }

    private var nameField: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            TextField("Name this place", text: $placeName)
                .submitLabel(.done)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
        .accessibilityLabel("Name for this place")
    }

    private var triggerPicker: some View {
        Picker("When to remind me", selection: $trigger) {
            ForEach(GeofenceTrigger.allCases) { option in
                Label(option.title, systemImage: option.icon).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: trigger) { _, _ in Haptics.selection() }
    }

    private var radiusPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Trigger within")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.distance(metres: radius))
                    .font(.footnote.weight(.semibold))
                    .contentTransition(.numericText())
            }
            HStack(spacing: 6) {
                ForEach(Self.radiusOptions, id: \.self) { option in
                    Button {
                        withAnimation(Motion.content) { radius = option }
                        Haptics.selection()
                        recentreOnPin()
                    } label: {
                        Text(Format.distance(metres: option))
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(radius == option ? Color.accentColor : .primary)
                }
            }
        }
    }

    // MARK: - Actions

    private func setPin(to coordinate: CLLocationCoordinate2D, name: String?) {
        withAnimation(Motion.content) {
            pin = coordinate
            if let name { placeName = name }
        }
        Haptics.medium()
        recentreOnPin()
        loadLookAround(for: coordinate)

        // Fill in a name from the map if the user has not typed one.
        if placeName.isEmpty { reverseGeocode(coordinate) }
    }

    private func recentreOnPin() {
        guard let pin else { return }
        withAnimation(Motion.surface) {
            camera = .region(MKCoordinateRegion(
                center: pin,
                latitudinalMeters: radius * 6,
                longitudinalMeters: radius * 6
            ))
        }
    }

    private func select(_ item: MKMapItem) {
        searchFocused = false
        searchText = ""
        results = []
        setPin(to: item.location.coordinate, name: item.name)
    }

    /// Debounced so typing "supermarket" fires one request, not eleven.
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            performSearch(trimmed)
        }
    }

    private func performSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Bias results to what the user is looking at, so "the co-op" finds the
        // one down the road rather than one in another country.
        if let visibleRegion { request.region = visibleRegion }

        Task {
            defer { isSearching = false }
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                withAnimation(Motion.content) { results = response.mapItems }
            } catch {
                // A failed search is not worth a banner — the user can tap the
                // map instead, and the empty result says enough.
                results = []
            }
        }
    }

    private func centreOnUser() async {
        guard !location.isDenied else {
            errorMessage = "Location access is off. You can still search or tap the map."
            return
        }
        errorMessage = nil

        guard let current = await location.currentLocation() else {
            errorMessage = "Couldn't get your location. Try searching instead."
            return
        }
        setPin(to: current.coordinate, name: nil)
    }

    private func loadLookAround(for coordinate: CLLocationCoordinate2D) {
        lookAroundScene = nil
        Task {
            let request = MKLookAroundSceneRequest(coordinate: coordinate)
            // Look Around has no coverage in most of the world; a nil scene just
            // means the preview is skipped.
            lookAroundScene = try? await request.scene
        }
    }

    /// Names a dropped pin from the map's own data, so a tap on the corner shop
    /// comes back as "Corner Shop" rather than a bare coordinate.
    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        Task {
            guard let request = MKReverseGeocodingRequest(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            ) else { return }

            let items = try? await request.mapItems
            guard let item = items?.first, placeName.isEmpty else { return }
            placeName = item.name
                ?? item.address?.shortAddress
                ?? "Saved place"
        }
    }

    /// Writes the pin. The endpoints differ by one path segment; everything
    /// else about this screen is identical for a list and an item.
    private func commit(pin: CLLocationCoordinate2D) async throws(APIError) {
        let name = placeName.trimmingCharacters(in: .whitespaces)
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
    }

    private func clear() async {
        switch target {
        case .list(let list):
            await store.clearListLocation(listId: list.id)
        case .item(let listId, let todo):
            await store.clearItemLocation(listId: listId, todoId: todo.id)
        }
    }

    private func save() {
        guard let pin else { return }
        isSaving = true
        errorMessage = nil

        Task {
            defer { isSaving = false }
            do {
                try await commit(pin: pin)
                Haptics.success()

                // Now that a reminder exists, ask for the permission that makes
                // it work when the app is closed. Asking before this point would
                // have been a prompt with nothing to justify it.
                if location.needsAlwaysUpgrade {
                    showingAlwaysPrompt = true
                } else {
                    if location.authorization == .notDetermined { location.requestWhenInUse() }
                    dismiss()
                }
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }

    // MARK: - Formatting

    private func shortAddress(for item: MKMapItem) -> String? {
        item.address?.shortAddress
    }

    private func symbol(for item: MKMapItem) -> String {
        switch item.pointOfInterestCategory {
        case .some(.cafe): "cup.and.saucer"
        case .some(.restaurant): "fork.knife"
        case .some(.store), .some(.foodMarket): "cart"
        case .some(.pharmacy): "cross.case"
        case .some(.hospital): "cross"
        case .some(.school), .some(.university): "graduationcap"
        case .some(.park): "tree"
        case .some(.airport): "airplane"
        case .some(.gasStation): "fuelpump"
        case .some(.parking): "parkingsign"
        case .some(.fitnessCenter): "figure.run"
        default: "mappin"
        }
    }
}
