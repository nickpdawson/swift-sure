import Foundation
import Observation

@MainActor
@Observable
final class SubscriptionAccessStore {
  private(set) var isChecking = true
  private(set) var accessEnd: Date?
  private(set) var renewalCancelled = false
  private(set) var message: String?
  private(set) var isBusy = false
  private(set) var plans: [SubscriptionPlan] = []
  private var expiryTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private let waitUntil: @Sendable (Date) async throws -> Void
  private let service: any SubscriptionServicing
  let gate: BackendAccessGate

  init(
    service: any SubscriptionServicing,
    gate: BackendAccessGate,
    waitUntil: @escaping @Sendable (Date) async throws -> Void
  ) {
    self.waitUntil = waitUntil
    self.service = service
    self.gate = gate
  }

  var hasAccess: Bool {
    #if SURE_SELF_HOSTED
    return gate.isAllowed
    #else
    return !isChecking && accessEnd != nil && gate.isAllowed
    #endif
  }

  func monitor() async {
    // Observe while loading the initial snapshot so purchase changes are not missed.
    async let updates: Void = service.observe { [weak self] in await self?.refresh() }
    await refresh()
    await updates
  }

  func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    let entitlement = await service.entitlement()
    guard generation == refreshGeneration else { return }
    gate.update(expiration: entitlement?.expiration)
    accessEnd = entitlement?.expiration
    renewalCancelled = entitlement?.renewalCancelled ?? false
    isChecking = false
    expiryTask?.cancel()
    if let end = entitlement?.expiration {
      let waitUntil = waitUntil
      expiryTask = Task { [weak self] in
        do { try await waitUntil(end) }
        catch { return }
        self?.gate.update(expiration: nil)
        self?.accessEnd = nil
        await self?.refresh()
      }
    }
    do { plans = try await service.plans() }
    catch { message = String(localized: "Subscriptions are unavailable. Please try again or restore a purchase.") }
  }

  func purchase(_ plan: SubscriptionPlan) async {
    guard !isBusy else { return }
    isBusy = true
    message = nil
    defer { isBusy = false }
    do {
      switch try await service.purchase(plan.id) {
      case .completed: await refresh()
      case .pending: message = String(localized: "Your purchase is awaiting approval. Backend sign-in remains locked.")
      case .cancelled: break
      }
    } catch { message = String(localized: "The purchase could not be verified or completed. Please try again.") }
  }

  func restore() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await service.restore()
      await refresh()
      message = hasAccess ? nil : String(localized: "No active subscription was found for this Apple Account.")
    } catch { message = String(localized: "Purchases could not be restored. Please try again.") }
  }
}
