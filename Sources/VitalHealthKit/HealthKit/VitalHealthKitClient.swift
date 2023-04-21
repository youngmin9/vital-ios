import HealthKit
import Combine
import os.log
import VitalCore

public enum PermissionOutcome: Equatable {
  case success
  case failure(String)
  case healthKitNotAvailable
}

let health_secureStorageKey: String = "health_secureStorageKey"

internal var logger: Logger? {
  VitalHealthKitClient.shared.logger
}

@objc public class VitalHealthKitClient: NSObject {
  public enum Status {
    case failedSyncing(VitalResource, Error?)
    case successSyncing(VitalResource, ProcessedResourceData)
    case nothingToSync(VitalResource)
    case syncing(VitalResource)
    case syncingCompleted
  }
  
  public static var shared: VitalHealthKitClient {
    clientInitLock.withLock {
      guard let value = client else {
        let newClient = VitalHealthKitClient()
        Self.client = newClient
        return newClient
      }

      return value
    }
  }

  private static let clientInitLock = NSLock()
  private static var client: VitalHealthKitClient?

  private let store: VitalHealthKitStore
  private let storage: VitalHealthKitStorage
  private let secureStorage: VitalSecureStorage
  private let vitalClient: VitalClientProtocol
  
  private let _status: PassthroughSubject<Status, Never>
  private var backgroundDeliveryTask: Task<Void, Error>? = nil
  
  private let backgroundDeliveryEnabled: ProtectedBox<Bool> = .init(value: false)
  let configuration: ProtectedBox<Configuration>
  
  public var status: AnyPublisher<Status, Never> {
    return _status.eraseToAnyPublisher()
  }
  
  fileprivate var logger: Logger? = nil
  
  init(
    configuration: ProtectedBox<Configuration> = .init(),
    store: VitalHealthKitStore = .live,
    storage: VitalHealthKitStorage = .init(storage: .live),
    secureStorage: VitalSecureStorage = .init(keychain: .live),
    vitalClient: VitalClientProtocol = .live
  ) {
    self.store = store
    self.storage = storage
    self.secureStorage = secureStorage
    self.vitalClient = vitalClient
    self.configuration = configuration
    
    self._status = PassthroughSubject<Status, Never>()
    
    super.init()
  }
  
  /// Only use this method if you are working from Objc.
  /// Please use the async/await configure method when working from Swift.
  @objc public static func configure(
    backgroundDeliveryEnabled: Bool = false,
    numberOfDaysToBackFill: Int = 90,
    logsEnabled: Bool = true
  ) {
    configure(
      .init(
        backgroundDeliveryEnabled: backgroundDeliveryEnabled,
        numberOfDaysToBackFill: numberOfDaysToBackFill,
        logsEnabled: logsEnabled,
        mode: .automatic
      )
    )
  }

  // IMPORTANT: The synchronous `configure(3)` is the preferred version over this async one.
  //
  // The async overload is still kept here for source compatibility, because Swift always ignores
  // the non-async overload sharing the same method signature, even if the async version is
  // deprecated.
  @_disfavoredOverload
  public static func configure(
    _ configuration: Configuration = .init()
  ) async {
    self.shared.setConfiguration(configuration: configuration)
  }
  
  public static func configure(
    _ configuration: Configuration = .init()
  ) {
    self.shared.setConfiguration(configuration: configuration)
  }

  @objc(automaticConfigurationWithCompletion:)
  public static func automaticConfiguration(completion: (() -> Void)? = nil) {
    do {
      let secureStorage = self.shared.secureStorage
      guard let payload: Configuration = try secureStorage.get(key: health_secureStorageKey) else {
        completion?()
        return
      }
      
      configure(payload)
      VitalClient.automaticConfiguration(completion: completion)
    } catch let error {
      completion?()
      /// Bailout, there's nothing else to do here.
      /// (But still try to log it if we have a logger around)
      shared.logger?.error("Failed to perform automatic configuration: \(error, privacy: .public)")
    }
  }

  /// **Synchronously** set the configuration and kick off the side effects.
  ///
  /// - important: This cannot not be `async` due to background observer registration
  /// timing requirement by HealthKit. Instead, spawn async tasks if necessary,
  func setConfiguration(
    configuration: Configuration
  ) {
    if configuration.logsEnabled {
      self.logger = Logger(subsystem: "vital", category: "vital-healthkit-client")
    }
    
    do {
      try secureStorage.set(value: configuration, key: health_secureStorageKey)
    }
    catch {
      logger?.info("We weren't able to securely store Configuration: \(error, privacy: .public)")
    }
    
    self.configuration.set(value: configuration)
    
    if backgroundDeliveryEnabled.value != true {
      backgroundDeliveryEnabled.set(value: true)
      
      let resources = self.store.permittedResources()
      checkBackgroundUpdates(isBackgroundEnabled: configuration.backgroundDeliveryEnabled, resources: resources)
    }
  }
}

public extension VitalHealthKitClient {
  struct Configuration: Codable {
    public enum DataPushMode: String, Codable {
      case manual
      case automatic
      
      var isManual: Bool {
        switch self {
          case .manual:
            return true
          case .automatic:
            return false
        }
      }
      
      var isAutomatic: Bool {
        return isManual == false
      }
    }
    
    public let backgroundDeliveryEnabled: Bool
    public let numberOfDaysToBackFill: Int
    public let logsEnabled: Bool
    public let mode: DataPushMode
    
    public init(
      backgroundDeliveryEnabled: Bool = false,
      numberOfDaysToBackFill: Int = 90,
      logsEnabled: Bool = true,
      mode: DataPushMode = .automatic
    ) {
      self.backgroundDeliveryEnabled = backgroundDeliveryEnabled
      self.numberOfDaysToBackFill = min(numberOfDaysToBackFill, 90)
      self.logsEnabled = logsEnabled
      self.mode = mode
    }
  }
}

extension VitalHealthKitClient {
  
  private func checkBackgroundUpdates(isBackgroundEnabled: Bool, resources: Set<VitalResource>) {
    guard isBackgroundEnabled else { return }
    guard resources.isEmpty == false else { return }
    
    /// If it's already running, cancel it
    self.backgroundDeliveryTask?.cancel()

    let typesToObserveByResource = Dictionary(
      resources
        .map { ($0, sampleTypesToTriggerSync(for: $0)) }
        .filter { _, types in types.isEmpty == false },
      uniquingKeysWith: { $0 + $1 }
    )

    if typesToObserveByResource.isEmpty {
      logger?.info("Not observing any type")
      return
    }

    let typesToObserve = Set(typesToObserveByResource.values.flatMap { $0 })

    /// Enable background deliveries
    enableBackgroundDelivery(for: typesToObserve)

    let stream: AsyncStream<BackgroundDeliveryPayload>

    if #available(iOS 15.0, *) {
      stream = bundledBackgroundObservers(for: typesToObserveByResource)
    } else {
      stream = backgroundObservers(for: typesToObserveByResource)
    }

    self.backgroundDeliveryTask = Task(priority: .high) {
      for await payload in stream {
        // If the task is cancelled, we would break the endless iteration and end the task.
        // Any buffered payload would not be processed, and is expected to be redelivered by
        // HealthKit.
        //
        // > https://developer.apple.com/documentation/healthkit/hkhealthstore/1614175-enablebackgrounddelivery#3801028
        // > If you don’t call the update’s completion handler, HealthKit continues to attempt to
        // > launch your app using a backoff algorithm to increase the delay between attempts.
        try Task.checkCancellation()

        // Task is not cancelled — we must call the HealthKit completion handler irrespective of
        // the sync process outcome. This is to avoid triggering the "strike on 3rd missed delivery"
        // rule of HealthKit background delivery.
        //
        // Since we have fairly frequent delivery anyway, each of which will implicit retry from
        // where the last sync has left off, this unconfigurable exponential backoff retry
        // behaviour adds little to no value in maintaining data freshness.
        //
        // (except for the task cancellation redelivery expectation stated above).
        defer { payload.completion() }

        logger?.info("[BackgroundDelivery] Dequeued payload for \(payload.resource.logDescription, privacy: .public)")

        await sync(payload: .resource(payload.resource))
      }
    }
  }
  
  private func enableBackgroundDelivery(for sampleTypes: Set<HKSampleType>) {
    for sampleType in sampleTypes {
      store.enableBackgroundDelivery(sampleType, .hourly) { [weak self] success, failure in
        
        guard failure == nil && success else {
          self?.logger?.error("Failed to enable background delivery for type: \(sampleType.identifier, privacy: .public). Did you enable \"Background Delivery\" in Capabilities?")
          return
        }
        
        self?.logger?.info("Successfully enabled background delivery for type: \(sampleType.identifier, privacy: .public)")
      }
    }
  }

  @available(iOS 15.0, *)
  private func bundledBackgroundObservers(
    for typesBundle: [VitalResource: Set<HKSampleType>]
  ) -> AsyncStream<BackgroundDeliveryPayload> {

    return AsyncStream<BackgroundDeliveryPayload> { continuation in
      var queries: [HKObserverQuery] = []

      for (resource, types) in typesBundle {

        let descriptors = types.map {
          HKQueryDescriptor(sampleType: $0, predicate: nil)
        }

        let query = HKObserverQuery(queryDescriptors: descriptors) { [weak self] query, sampleTypes, handler, error in
          guard error == nil else {
            self?.logger?.error("Failed to background deliver for \(resource.logDescription, privacy: .public) with \(error, privacy: .public).")


            ///  We need a better way to handle if a failure happens here.
            return
          }

          self?.logger?.info("[HealthKit] Notified changes in \(resource.logDescription, privacy: .public) caused by \(String(describing: sampleTypes ?? []), privacy: .public)")

          let payload = BackgroundDeliveryPayload(resource: resource, completion: handler)
          continuation.yield(payload)
        }

        queries.append(query)
        store.execute(query)
      }

      /// If the task is cancelled, make sure we clean up the existing queries
      continuation.onTermination = { @Sendable [queries] _ in
        queries.forEach { query in
          self.store.stop(query)
        }
      }
    }
  }
  
  private func backgroundObservers(
    for typesBundle: [VitalResource: Set<HKSampleType>]
  ) -> AsyncStream<BackgroundDeliveryPayload> {
    
    return AsyncStream<BackgroundDeliveryPayload> { continuation in
      
      var queries: [HKObserverQuery] = []

      let resourceAndTypes = typesBundle.flatMap { resource, types in
        types.map { (resource, $0) }
      }
      
      for (resource, sampleType) in resourceAndTypes {
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {[weak self] query, handler, error in
          
          guard error == nil else {
            self?.logger?.error("Failed to background deliver for \(sampleType.identifier, privacy: .public).")
            
            ///  We need a better way to handle if a failure happens here.
            return
          }

          self?.logger?.info("[HealthKit] Notified changes in \(sampleType, privacy: .public) caused by \(sampleType.identifier, privacy: .public)")
          
          let payload = BackgroundDeliveryPayload(resource: resource, completion: handler)
          continuation.yield(payload)
        }
        
        queries.append(query)
        store.execute(query)
      }
      
      /// If the task is cancelled, make sure we clean up the existing queries
      continuation.onTermination = { @Sendable [queries] _ in
        queries.forEach { query in
          self.store.stop(query)
        }
      }
    }
  }
  
  private func calculateStage(
    resource: VitalResource,
    startDate: Date,
    endDate: Date
  ) -> TaggedPayload.Stage  {
    
    /// We don't keep a historical record for profile data
    if resource == .profile {
      return .daily
    }
    
    return storage.readFlag(for: resource) ? .daily : .historical(start: startDate, end: endDate)
  }
  
  public func syncData() {
    let resources = Array(store.permittedResources())
    syncData(for: resources)
  }
  
  public func syncData(for resources: [VitalResource]) {
    Task(priority: .high) {
      for resource in resources {
        await sync(payload: .resource(resource))
      }
      
      _status.send(.syncingCompleted)
    }
  }
  
  public func cleanUp() async {
    await store.disableBackgroundDelivery()
    backgroundDeliveryTask?.cancel()
    
    backgroundDeliveryEnabled.set(value: false)
    
    await VitalClient.shared.cleanUp()
    self.secureStorage.clean(key: health_secureStorageKey)
  }
  
  public enum SyncPayload {
    case resource(VitalResource)
    
    var isResource: Bool {
      switch self {
        case .resource:
          return true
      }
    }

    var infix: String {
      if isResource {
        return ""
      } else {
        return "(via background delivery mechanism)"
      }
    }
    
    func description(store: VitalHealthKitStore) -> String {
      switch self {
        case let .resource(resource):
          return resource.logDescription
      }
    }
    
    func resource(store: VitalHealthKitStore) -> VitalResource {
      switch self {
        case let .resource(resource):
          return resource
      }
    }
  }
  
  private func sync(
    payload: SyncPayload
  ) async {
    
    let configuration = await configuration.get()
    let startDate: Date = .dateAgo(days: configuration.numberOfDaysToBackFill)
    let endDate: Date = Date()
    
    let infix = payload.infix
    let description = payload.description(store: store)
    let resource = payload.resource(store: store)
    
    logger?.info("Syncing HealthKit \(infix, privacy: .public): \(description, privacy: .public)")
    
    do {
      // Signal syncing (so the consumer can convey it to the user)
      _status.send(.syncing(resource))
      
      // Fetch from HealthKit
      let (data, entitiesToStore): (ProcessedResourceData?, [StoredAnchor])
      
      (data, entitiesToStore) = try await store.readResource(
        resource,
        startDate,
        endDate,
        storage
      )
      
      let stage = calculateStage(
        resource: payload.resource(store: store),
        startDate: startDate,
        endDate: endDate
      )

      guard let data = data, data.shouldSkipPost == false else {
        /// If there's no data, independently of the stage, we won't send it.
        /// Currently the server is returning 4XX when sending an empty payload.
        /// More context on VIT-2232.

        /// If it's historical, we store the entity and bailout
        if stage.isDaily == false {
          entitiesToStore.forEach(storage.store(entity:))
        }

        logger?.info("Skipping. No new data available \(infix, privacy: .public): \(description, privacy: .public)")
        _status.send(.nothingToSync(resource))

        return
      }
      
      if configuration.mode.isAutomatic {
        self.logger?.info(
          "Automatic Mode. Posting data for stage \(stage, privacy: .public) \(infix, privacy: .public): \(description, privacy: .public)"
        )
        
        /// Make sure the user has a connected source set up
        try await vitalClient.checkConnectedSource(.appleHealthKit)
        
        let transformedData = transform(data: data, calendar: vitalCalendar)

        // Post data
        try await vitalClient.post(
          transformedData,
          stage,
          .appleHealthKit,
          /// We can't use `vitalCalendar` here. We want to send the user's timezone
          /// rather than UTC (which is what `vitalCalendar` is set to).
          TimeZone.current
        )
      } else {
        self.logger?.info(
          "Manual Mode. Skipping posting data for stage \(stage, privacy: .public) \(infix, privacy: .public): \(description, privacy: .public)"
        )
      }
      
      // This is used for calculating the stage (daily vs historical)
      storage.storeFlag(for: resource)
      
      // Save the anchor/date on a succesfull network call
      entitiesToStore.forEach(storage.store(entity:))
      
      logger?.info("Completed syncing \(infix, privacy: .public): \(description, privacy: .public)")
      
      // Signal success
      _status.send(.successSyncing(resource, data))
    }
    catch let error {
      // Signal failure
      logger?.error(
        "Failed syncing data \(infix, privacy: .public): \(description, privacy: .public). Error: \(error, privacy: .public)"
      )
      _status.send(.failedSyncing(resource, error))
    }
  }
  
  public func ask(
    readPermissions readResources: [VitalResource],
    writePermissions writeResource: [WritableVitalResource]
  ) async -> PermissionOutcome {
    
    guard store.isHealthDataAvailable() else {
      return .healthKitNotAvailable
    }
    
    do {
      try await store.requestReadWriteAuthorization(readResources, writeResource)

      if configuration.isNil() == false {
        let configuration = await configuration.get()
        
        checkBackgroundUpdates(
          isBackgroundEnabled: configuration.backgroundDeliveryEnabled,
          resources: Set(readResources)
        )
      }
      
      return .success
    }
    catch let error {
      return .failure(error.localizedDescription)
    }
  }
  
  public func hasAskedForPermission(resource: VitalResource) -> Bool {
    store.hasAskedForPermission(resource)
  }
  
  public func dateOfLastSync(for resource: VitalResource) -> Date? {
    guard hasAskedForPermission(resource: resource) else {
      return nil
    }
    
    let dates: [Date] = toHealthKitTypes(resource: resource).map {
      String(describing: $0.self)
    }.compactMap { key in
      storage.read(key: key)?.date
    }
    
    /// This is not technically correct, because a resource (e.g. activity) can be made up of many types.
    /// In this case, we pick up the most recent one.
    return dates.sorted { $0.compare($1) == .orderedDescending }.first
  }
}

extension VitalHealthKitClient {
  public static func read(resource: VitalResource, startDate: Date, endDate: Date) async throws -> ProcessedResourceData? {
    let (data, _) = try await VitalHealthKitClient.shared.store.readResource(
      resource,
      startDate,
      endDate,
      VitalHealthKitStorage(storage: .debug)
    )

    if let data = data {
      return transform(data: data, calendar: vitalCalendar)
    }

    return nil
  }
}

extension VitalHealthKitClient {
  public func write(input: DataInput, startDate: Date, endDate: Date) async throws -> Void {
    try await self.store.writeInput(input, startDate, endDate)
  }
  
  public static func write(input: DataInput, startDate: Date, endDate: Date) async throws -> Void {
    let store = HKHealthStore()
    try await VitalHealthKit.write(healthKitStore: store, dataInput: input, startDate: startDate, endDate: endDate)
  }
}

func transform(data: ProcessedResourceData, calendar: Calendar) -> ProcessedResourceData {
  switch data {
    case .summary(.activity):
      return data

    case let .summary(.workout(patch)):
      let workouts = patch.workouts.map { workout in
        WorkoutPatch.Workout(
          id: workout.id,
          startDate: workout.startDate,
          endDate: workout.endDate,
          sourceBundle: workout.sourceBundle,
          productType: workout.productType,
          sport: workout.sport,
          calories: workout.calories,
          distance: workout.distance,
          heartRate: average(workout.heartRate, calendar: calendar),
          respiratoryRate: average(workout.respiratoryRate, calendar: calendar)
        )
      }
      
      return .summary(.workout(WorkoutPatch(workouts: workouts)))

    case let.summary(.sleep(patch)):
      let sleep = patch.sleep.map { sleep in
        SleepPatch.Sleep(
          id: sleep.id,
          startDate: sleep.startDate,
          endDate: sleep.endDate,
          sourceBundle: sleep.sourceBundle,
          productType: sleep.productType,
          heartRate: average(sleep.heartRate, calendar: calendar),
          restingHeartRate: average(sleep.restingHeartRate, calendar: calendar),
          heartRateVariability: average(sleep.heartRateVariability, calendar: calendar),
          oxygenSaturation: average(sleep.oxygenSaturation, calendar: calendar),
          respiratoryRate: average(sleep.respiratoryRate, calendar: calendar),
          sleepStages: sleep.sleepStages
        )
      }

      return .summary(.sleep(SleepPatch(sleep: sleep)))
      
    case .summary(.body), .summary(.profile):
      return data
      
    case let .timeSeries(.heartRate(samples)):
      let newSamples = average(samples, calendar: calendar)
      return .timeSeries(.heartRate(newSamples))
      
    case .timeSeries(.bloodPressure), .timeSeries(.glucose), .timeSeries(.nutrition), .timeSeries(.mindfulSession), .timeSeries(.heartRateVariability):
      return data
  }
}
