import Foundation

struct FinanceKitPublisherEnvironment: Sendable {
  static let applicationGroupIdentifier = "group.com.shifthuman.sure.financekit"
  static let keychainGroupInfoKey = "SureFinanceKitKeychainAccessGroup"

  var stateURL: URL
  var lockURL: URL
  var revocationURL: URL
  var keychainAccessGroup: String

  static func live(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> FinanceKitPublisherEnvironment {
    guard let container = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
    ),
    let keychainAccessGroup = bundle.object(
      forInfoDictionaryKey: keychainGroupInfoKey
    ) as? String,
    !keychainAccessGroup.isEmpty,
    !keychainAccessGroup.contains("$(") else {
      throw FinanceKitPublisherEnvironmentError.unavailable
    }
    let directory = container.appendingPathComponent("Publisher", isDirectory: true)
    return FinanceKitPublisherEnvironment(
      stateURL: directory.appendingPathComponent("state.json"),
      lockURL: directory.appendingPathComponent("publisher.lock"),
      revocationURL: directory.appendingPathComponent("revoked"),
      keychainAccessGroup: keychainAccessGroup
    )
  }
}

enum FinanceKitPublisherEnvironmentError: Error {
  case unavailable
}
