import Foundation
import os.log

let sdk_version = "0.10.2"

struct Credentials: Equatable, Hashable {
  let apiKey: String
  let environment: Environment
}

struct VitalCoreConfiguration {
  let apiVersion: String
  let apiClient: APIClient
  let environment: Environment
  let storage: VitalCoreStorage
  let authMode: VitalClient.AuthMode
  let jwtAuth: VitalJWTAuth
}

struct VitalClientRestorationState: Codable {
  let configuration: VitalClient.Configuration
  let apiVersion: String

  // Backward compatibility with Legacy API Key mode
  let apiKey: String?
  let environment: Environment?

  // Nullable for compatibility
  let strategy: ConfigurationStrategy?

  func resolveStrategy() throws -> ConfigurationStrategy {
    if let strategy = strategy {
      return strategy
    }

    if let apiKey = apiKey, let environment = environment {
      return .apiKey(apiKey, environment)
    }

    throw DecodingError.dataCorrupted(
      .init(codingPath: [], debugDescription: "persisted SDK configuration seems corrupted")
    )
  }
}

enum ConfigurationStrategy: Hashable, Codable {
  case apiKey(String, Environment)
  case jwt(Environment)

  var environment: Environment {
    switch self {
    case let .apiKey(_, environment):
      return environment
    case let .jwt(environment):
      return environment
    }
  }
}

public enum Environment: Equatable, Hashable, Codable, CustomStringConvertible {
  public enum Region: String, Equatable, Hashable, Codable {
    case eu
    case us
    
    var name: String {
      switch self {
        case .eu:
          return "eu"
        case .us:
          return "us"
      }
    }
  }
  
  case dev(Region)
  case sandbox(Region)
  case production(Region)

#if DEBUG
  case local(Region)
#endif

  init?(environment: String, region: String) {
    switch(environment, region) {
    case ("production", "us"), ("prd", "us"):
      self = .production(.us)
    case ("production", "eu"), ("prd", "eu"):
      self = .production(.eu)
    case ("sandbox", "us"), ("stg", "us"):
      self = .sandbox(.us)
    case ("sandbox", "eu"), ("stg", "eu"):
      self = .sandbox(.eu)
    case ("dev", "us"):
      self = .dev(.us)
    case ("dev", "eu"):
      self = .dev(.eu)
#if DEBUG
    case ("local", "eu"):
      self = .local(.eu)
    case ("local", "eu"):
      self = .local(.eu)
#endif
      case (_, _):
        return nil
    }
  }
  
  var host: String {
    switch self {
      case .dev(.eu):
        return "https://api.dev.eu.tryvital.io"
      case .dev(.us):
        return "https://api.dev.tryvital.io"
      case .sandbox(.eu):
        return "https://api.sandbox.eu.tryvital.io"
      case .sandbox(.us):
        return "https://api.sandbox.tryvital.io"
      case .production(.eu):
        return "https://api.eu.tryvital.io"
      case .production(.us):
        return "https://api.tryvital.io"
      #if DEBUG
      case .local:
        return "http://localhost:8000"
      #endif
    }
  }
  
  var name: String {
    switch self {
      case .dev:
        return "dev"
      case .sandbox:
        return "sandbox"
      case .production:
        return "production"
#if DEBUG
      case .local:
        return "local"
#endif
    }
  }
  
  var region: Region {
    switch self {
      case .dev(let region):
        return region
      case .sandbox(let region):
        return region
      case .production(let region):
        return region
#if DEBUG
      case .local(let region):
        return region
#endif
    }
  }

  public var description: String {
    "\(name) - \(region.name)"
  }
}

let core_secureStorageKey: String = "core_secureStorageKey"
let user_secureStorageKey: String = "user_secureStorageKey"

@objc public class VitalClient: NSObject {
  
  private let secureStorage: VitalSecureStorage
  let configuration: ProtectedBox<VitalCoreConfiguration>

  // @testable
  internal let apiKeyModeUserId: ProtectedBox<UUID>
  
  private static var client: VitalClient?
  private static let clientInitLock = NSLock()

  private static var signInTokenFetcher: (@Sendable (_ vitalUserId: String) async -> String?)? = nil
  private static var reauthenticationMonitor: Task<Void, Never>? = nil

  public static var shared: VitalClient {
    clientInitLock.withLock {
      guard let value = client else {
        let newClient = VitalClient()
        Self.client = newClient
        return newClient
      }

      return value
    }
  }

  // @testable
  internal static func setClient(_ client: VitalClient?) {
    clientInitLock.withLock { Self.client = client }
  }
  
  /// Only use this method if you are working from Objc.
  /// Please use the async/await configure method when working from Swift.
  @objc public static func configure(
    apiKey: String,
    environment: String,
    region: String,
    isLogsEnable: Bool
  ) {
    guard let environment = Environment(environment: environment, region: region) else {
      fatalError("Wrong environment and/or region. Acceptable values for environment: dev, sandbox, production. Region: eu, us")
    }

    configure(apiKey: apiKey, environment: environment, configuration: .init(logsEnable: isLogsEnable))
  }

  /// Sign-in the SDK with a User JWT — no API Key is needed.
  ///
  /// In this mode, your app requests a Vital Sign-In Token **through your backend service**, typically at the same time when
  /// your user sign-ins with your backend service. This allows your backend service to keep the API Key as a private secret.
  ///
  /// The environment and region is inferred from the User JWT. You need not specify them explicitly
  public static func signIn(
    withRawToken token: String,
    configuration: Configuration = .init()
  ) async throws {
    let signInToken = try VitalSignInToken.decode(from: token)
    let claims = try signInToken.unverifiedClaims()
    let jwtAuth = VitalJWTAuth.live

    try await jwtAuth.signIn(with: signInToken)

    // Configure the SDK only if we have signed in successfully.
    self.shared.setConfiguration(
      strategy: .jwt(claims.environment),
      configuration: configuration,
      storage: .init(storage: .live),
      apiVersion: "v2",
      jwtAuth: jwtAuth
    )

    let configuration = await shared.configuration.get()
    precondition(configuration.authMode == .userJwt)
  }

  /// Configure the SDK in the legacy API Key mode.
  ///
  /// API Key mode will continue to be supported. But users should plan to migrate to the User JWT mode.
  public static func configure(
    apiKey: String,
    environment: Environment,
    configuration: Configuration = .init()
  ) {
    self.shared.setConfiguration(
      strategy: .apiKey(apiKey, environment),
      configuration: configuration,
      storage: .init(storage: .live),
      apiVersion: "v2"
    )
  }

  // IMPORTANT: The synchronous `configure(3)` is the preferred version over this async one.
  //
  // The async overload is still kept here for source compatibility, because Swift always ignores
  // the non-async overload sharing the same method signature, even if the async version is
  // deprecated.
  @_disfavoredOverload
  public static func configure(
    apiKey: String,
    environment: Environment,
    configuration: Configuration = .init()
  ) async {
    self.shared.setConfiguration(
      strategy: .apiKey(apiKey, environment),
      configuration: configuration,
      storage: .init(storage: .live),
      apiVersion: "v2"
    )
  }

  public static var status: Status {
    var status = Status()

    if let configuration = self.shared.configuration.value {
      status.insert(.configured)

      switch configuration.authMode {
      case .apiKey:
        if self.shared.apiKeyModeUserId.value != nil {
          status.insert(.signedIn)
        }

      case .userJwt:
        if configuration.jwtAuth.currentUserId != nil {
          status.insert(.signedIn)
        }
      }
    }

    return status
  }

  public static var currentUserId: String? {
    if let configuration = self.shared.configuration.value {
      switch configuration.authMode {
      case .apiKey:
        return self.shared.apiKeyModeUserId.value?.uuidString
      case .userJwt:
        return configuration.jwtAuth.currentUserId
      }
    } else {
      return nil
    }
  }
  
  @objc(automaticConfigurationWithCompletion:)
  public static func automaticConfiguration(completion: (() -> Void)? = nil) {
    // If the SDK has been configured, skip automaticConfiguration.
    guard VitalClient.status.contains(.configured) == false else {
      completion?()
      return
    }

    do {
      /// Order is important. `configure` should happen before `setUserId`,
      /// because the latter depends on the former. If we don't do this, the app crash.
      if let restorationState: VitalClientRestorationState = try shared.secureStorage.get(key: core_secureStorageKey) {
        
        let strategy = try restorationState.resolveStrategy()

        /// 1) Set the configuration
        self.shared.setConfiguration(
          strategy: strategy,
          configuration: restorationState.configuration,
          storage: .init(storage: .live),
          apiVersion: "v2"
        )

        if
          case .apiKey = strategy,
          let userId: UUID = try shared.secureStorage.get(key: user_secureStorageKey)
        {
          /// 2) If and only if there's a `userId`, we set it.
          ///
          /// Note that this is only applicable to the Legacy API Key mode.
          /// In User JWT mode, user ID is part of the JWT claims, and VitalJWTAuth is fully responsible for its persistence.
          shared._setUserId(userId)
        }
      }

      completion?()
    } catch let error {
      completion?()
      /// Bailout, there's nothing else to do here.
      /// (But still try to log it if we have a logger around)
      VitalLogger.core.error("Failed to perform automatic configuration: \(error, privacy: .public)")
    }
  }

  /// Observe reauthentication requests, and respond to these requests by asynchronously fetching
  /// a new Vital Sign-In Token through your backend service.
  ///
  /// There are two scenarios where a reauthentication request may arise:
  ///
  /// **Migration from API Key mode**:
  ///
  /// An existing user in API Key mode has launched your app for the first time, after the app was upgraded to a new release that
  /// has adopted Vital Sign-In Token.
  ///
  /// After you setup `observeReauthenticationRequest`, the Vital SDK would automatically trigger it once to migrate the
  /// said user from API Key mode to Vital Sign-In Token mode.
  ///
  /// **Refresh Token invalidation**:
  ///
  /// Typically, reauthentication request would not arise due to refresh token invalidation.
  ///
  /// Vital's identity broker guarantees that the underlying refresh token is not invalidated, unless the user is disabled or deleted, or
  /// Vital explicitly revokes the refresh tokens (which we typically would not do so).
  ///
  /// However, Vital still recommends setting up `observeReauthenticationRequest`, so that
  /// the SDK can recover in event of a necessitated token revocation (announced by Vital, or requested by you).
  ///
  /// - warning: The supplied `signInTokenFetcher` is retained until the process is terminated, or until you explicitly clear it.
  /// - precondition: SDK has been configured.
  public static func observeReauthenticationRequest(
    _ signInTokenFetcher: (@Sendable (_ vitalUserId: String) async -> String?)?
  ) {
    guard Self.status.contains(.configured) else {
      fatalError("You need to configure the SDK with `VitalClient.configure` before using `observeReauthenticationRequest`")
    }

    // Reuse the client init lock for mutual exclusion of reauthentication monitor setup.
    clientInitLock.withLock {
      Self.signInTokenFetcher = signInTokenFetcher

      switch (Self.reauthenticationMonitor, signInTokenFetcher) {
      case (nil, .some):
        // Start a reauth monitor
        Self.reauthenticationMonitor = Task {
          // Check if we are in API Key mode
          // Perform a one-off migration to Vital Sign-In Token if needed.
          let configuration = await VitalClient.shared.configuration.get()

          func tryToReauthenticate(context: StaticString) async {
            if
              let fetcher = clientInitLock.withLock({ Self.signInTokenFetcher }),
              let userId = VitalClient.currentUserId
            {
              do {
                VitalLogger.core.info("reauth[\(context)] started")

                guard let signInToken = await fetcher(userId) else {
                  VitalLogger.core.info("reauth[\(context)] skipped by host")
                  return
                }

                try await VitalClient.signIn(withRawToken: signInToken)

                VitalLogger.core.info("reauth[\(context)] completed")
              } catch let error {
                VitalLogger.core.error("reauth[\(context)] failed: \(error)")
              }
            }
          }

          if configuration.authMode == .apiKey {
            await tryToReauthenticate(context: "api-key-migration")
          }

          if VitalJWTAuth.live.needsReauthentication {
            await tryToReauthenticate(context: "app-launch")
          }

          // Observe reauthentication requests from VitalJWTAuth.
          for await _ in VitalJWTAuth.live.reauthenticationRequests {
            // Double check that we still in fact needs to reauth.
            guard VitalJWTAuth.live.needsReauthentication else { continue }
            await tryToReauthenticate(context: "on-demand")
          }
        }

      case (let monitor?, nil):
        // Stop the reauth monitor.
        monitor.cancel()

      case (nil, nil), (.some, .some):
        // No-op
        break
      }
    }
  }
  
  init(
    secureStorage: VitalSecureStorage = .init(keychain: .live),
    configuration: ProtectedBox<VitalCoreConfiguration> = .init(),
    userId: ProtectedBox<UUID> = .init()
  ) {
    self.secureStorage = secureStorage
    self.configuration = configuration
    self.apiKeyModeUserId = userId
    
    super.init()
  }

  /// **Synchronously** set the configuration and kick off the side effects.
  ///
  /// - important: This cannot not be `async` due to background observer registration
  /// timing requirement by HealthKit in VitalHealthKit. Instead, spawn async tasks if necessary,
  func setConfiguration(
    strategy: ConfigurationStrategy,
    configuration: Configuration,
    storage: VitalCoreStorage,
    apiVersion: String,
    jwtAuth: VitalJWTAuth = .live,
    updateAPIClientConfiguration: (inout APIClient.Configuration) -> Void = { _ in }
  ) {
    
    VitalLogger.core.info("VitalClient setup for environment \(String(describing: strategy.environment), privacy: .public)")

    let authMode: VitalClient.AuthMode
    let authStrategy: VitalClientAuthStrategy
    let actualEnvironment: Environment

#if DEBUG
    if configuration.localDebug {
      actualEnvironment = .local(strategy.environment.region)
    } else {
      actualEnvironment = strategy.environment
    }
#else
    actualEnvironment = strategy.environment
#endif

    switch strategy {
    case let .apiKey(key, _):
      authStrategy = .apiKey(key)
      authMode = .apiKey

    case .jwt:
      authStrategy = .jwt(jwtAuth)
      authMode = .userJwt
    }

    let apiClientDelegate = VitalClientDelegate(
      environment: actualEnvironment,
      authStrategy: authStrategy
    )

    let apiClient = makeClient(environment: actualEnvironment, delegate: apiClientDelegate)
    
    let restorationState = VitalClientRestorationState(
      configuration: configuration,
      apiVersion: apiVersion,
      apiKey: nil,
      environment: nil,
      strategy: strategy
    )
    
    do {
      try secureStorage.set(value: restorationState, key: core_secureStorageKey)
    }
    catch {
      VitalLogger.core.info("We weren't able to securely store VitalClientRestorationState: \(error, privacy: .public)")
    }
    
    let coreConfiguration = VitalCoreConfiguration(
      apiVersion: apiVersion,
      apiClient: apiClient,
      environment: actualEnvironment,
      storage: storage,
      authMode: authMode,
      jwtAuth: VitalJWTAuth.live
    )
    
    self.configuration.set(value: coreConfiguration)
  }

  private func _setUserId(_ newUserId: UUID) {
    guard let configuration = configuration.value else {
      /// We don't have a configuration at this point, the only realistic thing to do is tell the user to
      fatalError("You need to call `VitalClient.configure` before setting the `userId`")
    }

    guard configuration.authMode == .apiKey else {
      VitalLogger.core.error("VitalClient.setUserId(_:) is ignored when the SDK is configured by a Vital Sign-In Token.")
      return
    }

    do {
      if
        let existingValue: UUID = try secureStorage.get(key: user_secureStorageKey), existingValue != newUserId {
        configuration.storage.clean()
      }
    }
    catch {
      VitalLogger.core.info("We weren't able to get the stored userId VitalClientRestorationState: \(error, privacy: .public)")
    }
    
    self.apiKeyModeUserId.set(value: newUserId)
    
    do {
      try secureStorage.set(value: newUserId, key: user_secureStorageKey)
    }
    catch {
      VitalLogger.core.info("We weren't able to securely store VitalClientRestorationState: \(error, privacy: .public)")
    }
  }

  @objc(setUserId:) public static func objc_setUserId(_ newUserId: UUID) {
    shared._setUserId(newUserId)
  }

  @nonobjc public static func setUserId(_ newUserId: UUID) async {
    shared._setUserId(newUserId)
  }
  
  public func isUserConnected(to provider: Provider.Slug) async throws -> Bool {
    let userId = try await getUserId()
    let storage = await configuration.get().storage
    
    guard storage.isConnectedSourceStored(for: userId, with: provider) == false else {
      return true
    }
    
    let connectedSources: [Provider] = try await self.user.userConnectedSources()
    return connectedSources.contains { $0.slug == provider }
  }
  
  public func checkConnectedSource(for provider: Provider.Slug) async throws {
    let userId = try await getUserId()
    let storage = await configuration.get().storage
    
    if try await isUserConnected(to: provider) == false {
      try await self.link.createConnectedSource(userId, provider: provider)
    }
    
    storage.storeConnectedSource(for: userId, with: provider)
  }
  
  public func cleanUp() async {
    /// Here we remove the following:
    /// 1) Anchor values we are storing for each `HKSampleType`.
    /// 2) Stage for each `HKSampleType`.
    ///
    /// We might be able to derive 2) from 1)?
    ///
    /// We need to check this first, otherwise it will suspend until a configuration is set
    if self.configuration.isNil() == false {
      await self.configuration.get().storage.clean()
    }
    
    self.secureStorage.clean(key: core_secureStorageKey)
    self.secureStorage.clean(key: user_secureStorageKey)
    
    self.apiKeyModeUserId.clean()
    self.configuration.clean()
  }

  internal func getUserId() async throws -> String {
    let configuration = await configuration.get()
    switch configuration.authMode {
    case .apiKey:
      return await apiKeyModeUserId.get().uuidString

    case .userJwt:
      // In User JWT mode, we need not wait for user ID to be set.
      // VitalUserJWT will lazy load the authenticated user from Keychain on first access.
      return try await configuration.jwtAuth.userContext().userId
    }
  }
}

extension VitalClient {
  @_spi(VitalTesting) public static func forceRefreshToken() async throws {
    let configuration = await shared.configuration.get()
    precondition(configuration.authMode == .userJwt)

    try await configuration.jwtAuth.refreshToken()
  }
}

public extension VitalClient {
  struct Configuration: Codable {
    public var logsEnable: Bool
    public var localDebug: Bool
    
    public init(
      logsEnable: Bool = false,
      localDebug: Bool = false
    ) {
      self.logsEnable = logsEnable
      self.localDebug = localDebug
    }
  }

  enum AuthMode: String, Codable {
    case apiKey
    case userJwt
  }

  struct Status: OptionSet {
    public static let configured = Status(rawValue: 1)
    public static let signedIn = Status(rawValue: 1 << 1)

    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }
}
