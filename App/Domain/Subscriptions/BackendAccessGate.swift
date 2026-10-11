import Foundation

/// One gate for every Sure network operation, including authentication and uploads.
final class BackendAccessGate: @unchecked Sendable {
  enum Permit: Equatable, Sendable {
    case subscription(Int)
    /// Public demo requests remain valid when a StoreKit entitlement changes.
    case demo
  }

  private let lock = NSLock()
  private var expiration: Date?
  private var generation = 0
  private var cancellations: [UUID: (Permit, @Sendable () -> Void)] = [:]
  private let now: @Sendable () -> Date

  init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

  /// Call under `lock`. Self-hosted builds (dzsec) have no StoreKit entitlement and are
  /// always entitled; the public build keeps the subscription expiration check.
  private var entitled: Bool {
    #if SURE_SELF_HOSTED
    return true
    #else
    return expiration.map { $0 > now() } == true
    #endif
  }

  var isAllowed: Bool { lock.withLock { entitled } }

  func isAllowed(for url: URL?) -> Bool {
    isAllowed || SureDemoServer.allowsRequest(to: url)
  }

  func update(expiration: Date?) {
    let callbacks = lock.withLock {
      self.expiration = expiration
      guard !entitled else { return [@Sendable () -> Void]() }
      generation += 1
      let subscriptionIDs = cancellations.compactMap { id, entry -> UUID? in
        guard case .subscription = entry.0 else { return nil }
        return id
      }
      let result = subscriptionIDs.compactMap { cancellations.removeValue(forKey: $0)?.1 }
      return result
    }
    callbacks.forEach { $0() }
  }

  func check() throws {
    guard isAllowed else { throw BackendAccessError.subscriptionRequired }
  }

  func check(for url: URL?) throws {
    guard isAllowed(for: url) else { throw BackendAccessError.subscriptionRequired }
  }

  func permit() throws -> Permit {
    try lock.withLock {
      guard entitled else { throw BackendAccessError.subscriptionRequired }
      return .subscription(generation)
    }
  }

  func permit(for url: URL?) throws -> Permit {
    if SureDemoServer.allowsRequest(to: url) { return .demo }
    return try permit()
  }

  func validate(_ permit: Permit, for url: URL? = nil) throws {
    try lock.withLock {
      let valid: Bool
      switch permit {
      case .subscription(let issuedGeneration):
        valid = generation == issuedGeneration && entitled
      case .demo:
        valid = SureDemoServer.allowsRequest(to: url)
      }
      guard valid else {
        throw BackendAccessError.subscriptionRequired
      }
    }
  }

  func register(_ id: UUID, permit: Permit, for url: URL? = nil,
                cancel: @escaping @Sendable () -> Void) throws {
    try lock.withLock {
      switch permit {
      case .subscription(let issuedGeneration):
        guard generation == issuedGeneration, entitled else {
          throw BackendAccessError.subscriptionRequired
        }
      case .demo:
        guard SureDemoServer.allowsRequest(to: url) else { throw BackendAccessError.subscriptionRequired }
      }
      cancellations[id] = (permit, cancel)
    }
  }

  func unregister(_ id: UUID) { lock.withLock { _ = cancellations.removeValue(forKey: id) } }
}

enum BackendAccessError: LocalizedError {
  case subscriptionRequired
  var errorDescription: String? {
    String(localized: "Sync is paused. Start or restore a subscription to connect to Sure. Downloaded data and local features remain available.")
  }
}
