import Foundation
import NotchRouterCore
import Testing
import UserNotifications

@testable import NotchRouterApp

@MainActor
@Test
func notificationDeliveryFiltersStatesAndPreservesActionURL() throws {
  let suiteName = "ActivityNotificationDeliveryTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: ActivityNotificationService.preferenceKey)

  var delivered: [UNNotificationRequest] = []
  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    notificationDeliverer: { delivered.append($0) }
  )
  let actionURL = URL(string: "https://example.com/review/42")!
  let states: [ActivityState] = [
    .queued, .running, .needsApproval, .stale, .succeeded, .failed, .cancelled,
  ]

  for state in states {
    let activity = AIActivity(
      event: ActivityEventRequest(
        activityID: state.rawValue,
        source: "Codex",
        title: "Release",
        state: state,
        message: state == .failed ? "Tests failed" : nil,
        actionURL: state == .needsApproval ? actionURL : nil
      ),
      now: Date(timeIntervalSince1970: 1_000)
    )
    service.deliverIfImportant(activity)
  }

  #expect(delivered.count == 3)
  #expect(
    delivered.map(\.identifier) == [
      "needs_approval-1000.0",
      "succeeded-1000.0",
      "failed-1000.0",
    ]
  )
  let approval = try #require(delivered.first)
  #expect(approval.content.title == "Codex: Release")
  #expect(approval.content.userInfo["action_url"] as? String == actionURL.absoluteString)
  #expect(delivered.last?.content.body == "Tests failed")
}

@MainActor
@Test
func notificationDeliveryHonorsGlobalAndPerKindPreferences() {
  let suiteName = "ActivityNotificationFilteringTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var delivered: [UNNotificationRequest] = []
  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    notificationDeliverer: { delivered.append($0) }
  )
  let completion = AIActivity(
    event: ActivityEventRequest(
      activityID: "completion",
      source: "Codex",
      title: "Build",
      state: .succeeded
    )
  )

  service.deliverIfImportant(completion)
  #expect(delivered.isEmpty)

  defaults.set(true, forKey: ActivityNotificationService.preferenceKey)
  let enabledService = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    notificationDeliverer: { delivered.append($0) }
  )
  enabledService.setEnabled(false, for: .completion)
  enabledService.deliverIfImportant(completion)
  #expect(delivered.isEmpty)

  enabledService.setEnabled(true, for: .completion)
  enabledService.deliverIfImportant(completion)
  #expect(delivered.count == 1)
}

@MainActor
@Test
func focusCompletionUsesIndependentSoundAndNotificationSettings() throws {
  let suiteName = "FocusNotificationDeliveryTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: ActivityNotificationService.preferenceKey)

  var soundCount = 0
  var delivered: [UNNotificationRequest] = []
  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    focusCompletionSoundPlayer: { soundCount += 1 },
    notificationDeliverer: { delivered.append($0) }
  )

  service.deliverFocusCompletion(durationMinutes: 25)
  #expect(soundCount == 0)
  #expect(delivered.isEmpty)

  service.setFocusCompletionNotificationsEnabled(true)
  service.setFocusCompletionSoundEnabled(true)
  service.deliverFocusCompletion(durationMinutes: 25)

  #expect(soundCount == 1)
  let request = try #require(delivered.first)
  #expect(request.identifier.hasPrefix("focus-"))
  #expect(request.content.title == "Focus session complete")
  #expect(request.content.body == "Your 25-minute focus session is complete.")
}

@MainActor
@Test
func notificationAuthorizationUpdatesPersistedState() async throws {
  let suiteName = "NotificationAuthorizationTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var requestedOptions: UNAuthorizationOptions = []
  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    authorizationRequester: { options, completion in
      requestedOptions = options
      completion(true, nil)
    }
  )

  service.setEnabled(true)
  #expect(service.isRequestingAuthorization)
  try await waitUntil { !service.isRequestingAuthorization }

  #expect(requestedOptions.contains(.alert))
  #expect(requestedOptions.contains(.sound))
  #expect(service.isEnabled)
  #expect(defaults.bool(forKey: ActivityNotificationService.preferenceKey))

  service.setEnabled(false)
  #expect(!service.isEnabled)
  #expect(!defaults.bool(forKey: ActivityNotificationService.preferenceKey))
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async throws {
  for _ in 0..<100 {
    if predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw NotificationTestError.timedOut
}

private enum NotificationTestError: Error {
  case timedOut
}
