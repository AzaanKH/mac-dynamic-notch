import Foundation
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func displaySelectionPersistsBehaviorAndPinnedDisplay() {
  let suiteName = "DisplaySelectionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let controller = DisplaySelectionController(defaults: defaults)
  #expect(controller.behavior == .pointer)

  controller.setPinnedDisplay("4242")
  controller.setBehavior(.pinned)

  #expect(controller.behavior == .pinned)
  #expect(controller.pinnedDisplayIdentifier == "4242")
  #expect(defaults.string(forKey: DisplaySelectionController.preferenceKey) == "4242")
  #expect(
    defaults.string(forKey: DisplaySelectionController.behaviorPreferenceKey)
      == DisplayBehavior.pinned.rawValue
  )

  controller.setBehavior(.activeWindow)

  let reloadedController = DisplaySelectionController(defaults: defaults)
  #expect(reloadedController.behavior == .activeWindow)
  #expect(reloadedController.pinnedDisplayIdentifier == "4242")
}

@MainActor
@Test
func displaySelectionMigratesExistingPinnedDisplayPreference() {
  let suiteName = "DisplaySelectionMigrationTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set("legacy-display", forKey: DisplaySelectionController.preferenceKey)

  let controller = DisplaySelectionController(defaults: defaults)

  #expect(controller.behavior == .pinned)
  #expect(controller.pinnedDisplayIdentifier == "legacy-display")
}

@MainActor
@Test
func displaySelectionMigratesAutomaticDisplayPreference() {
  let suiteName = "DisplaySelectionAutomaticMigrationTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(
    DisplaySelectionController.automaticIdentifier,
    forKey: DisplaySelectionController.preferenceKey
  )

  let controller = DisplaySelectionController(defaults: defaults)

  #expect(controller.behavior == .pointer)
  #expect(controller.pinnedDisplayIdentifier == nil)
  #expect(defaults.string(forKey: DisplaySelectionController.preferenceKey) == nil)
}

@MainActor
@Test
func externalDisplayVisibilityPreferencePersists() {
  let suiteName = "DisplayVisibilityTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let controller = DisplaySelectionController(defaults: defaults)
  controller.setHidesOnExternalDisplays(true)

  let reloadedController = DisplaySelectionController(defaults: defaults)
  #expect(reloadedController.hidesOnExternalDisplays)
}

@MainActor
@Test
func notificationTypesDefaultOnAndPersistIndependently() {
  let suiteName = "NotificationPreferenceTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false
  )
  #expect(service.isEnabled(for: .approval))
  #expect(service.isEnabled(for: .completion))
  #expect(service.isEnabled(for: .failure))

  service.setEnabled(false, for: .completion)

  let reloadedService = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false
  )
  #expect(reloadedService.isEnabled(for: .approval))
  #expect(!reloadedService.isEnabled(for: .completion))
  #expect(reloadedService.isEnabled(for: .failure))
}

@MainActor
@Test
func focusCompletionAlertsDefaultOffAndPersistIndependently() {
  let suiteName = "FocusCompletionPreferenceTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false
  )
  #expect(!service.focusCompletionNotificationsEnabled)
  #expect(!service.focusCompletionSoundEnabled)

  service.setFocusCompletionNotificationsEnabled(true)
  #expect(service.focusCompletionNotificationsEnabled)
  #expect(!service.focusCompletionSoundEnabled)

  service.setFocusCompletionSoundEnabled(true)

  let reloadedService = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false
  )
  #expect(reloadedService.focusCompletionNotificationsEnabled)
  #expect(reloadedService.focusCompletionSoundEnabled)
}

@MainActor
@Test
func focusCompletionSoundCanPlayWithoutSystemNotifications() {
  let suiteName = "FocusCompletionSoundTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var playCount = 0
  let service = ActivityNotificationService(
    defaults: defaults,
    configuresNotificationCenter: false,
    focusCompletionSoundPlayer: { playCount += 1 }
  )
  service.deliverFocusCompletion(durationMinutes: 25)
  #expect(playCount == 0)

  service.setFocusCompletionSoundEnabled(true)
  service.deliverFocusCompletion(durationMinutes: 25)

  #expect(!service.isEnabled)
  #expect(playCount == 1)
}
