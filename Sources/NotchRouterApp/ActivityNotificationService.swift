import AppKit
import Combine
import NotchRouterCore
import UserNotifications

enum ActivityNotificationKind: String, CaseIterable, Identifiable {
  case approval
  case completion
  case failure

  var id: String { rawValue }

  var title: String {
    switch self {
    case .approval: "Approval requests"
    case .completion: "Completed activities"
    case .failure: "Failed activities"
    }
  }

  var detail: String {
    switch self {
    case .approval: "When an agent needs a decision or permission."
    case .completion: "When an activity finishes successfully."
    case .failure: "When an activity reports a failure."
    }
  }
}

@MainActor
final class ActivityNotificationService: NSObject, ObservableObject,
  UNUserNotificationCenterDelegate
{
  typealias AuthorizationRequester = (
    UNAuthorizationOptions,
    @escaping @Sendable (Bool, Error?) -> Void
  ) -> Void
  typealias NotificationDeliverer = (UNNotificationRequest) -> Void

  static let preferenceKey = "systemNotificationsEnabled"
  static let approvalPreferenceKey = "approvalNotificationsEnabled"
  static let completionPreferenceKey = "completionNotificationsEnabled"
  static let failurePreferenceKey = "failureNotificationsEnabled"
  static let focusCompletionPreferenceKey =
    "focusCompletionNotificationsEnabled"
  static let focusCompletionSoundPreferenceKey =
    "focusCompletionSoundEnabled"

  @Published private(set) var isEnabled: Bool
  @Published private(set) var isRequestingAuthorization = false
  @Published private(set) var approvalNotificationsEnabled: Bool
  @Published private(set) var completionNotificationsEnabled: Bool
  @Published private(set) var failureNotificationsEnabled: Bool
  @Published private(set) var focusCompletionNotificationsEnabled: Bool
  @Published private(set) var focusCompletionSoundEnabled: Bool
  @Published private(set) var permissionMessage: String?

  private let defaults: UserDefaults
  private let focusCompletionSoundPlayer: () -> Void
  private let authorizationRequester: AuthorizationRequester
  private let notificationDeliverer: NotificationDeliverer

  init(
    defaults: UserDefaults = .standard,
    configuresNotificationCenter: Bool = true,
    focusCompletionSoundPlayer: @escaping () -> Void = {
      if let sound = NSSound(named: NSSound.Name("Glass")), sound.play() {
        return
      }
      NSSound.beep()
    },
    authorizationRequester: @escaping AuthorizationRequester = { options, completion in
      UNUserNotificationCenter.current().requestAuthorization(
        options: options,
        completionHandler: completion
      )
    },
    notificationDeliverer: @escaping NotificationDeliverer = { request in
      UNUserNotificationCenter.current().add(request)
    }
  ) {
    self.defaults = defaults
    self.focusCompletionSoundPlayer = focusCompletionSoundPlayer
    self.authorizationRequester = authorizationRequester
    self.notificationDeliverer = notificationDeliverer
    isEnabled = defaults.bool(forKey: Self.preferenceKey)
    approvalNotificationsEnabled = Self.preference(
      Self.approvalPreferenceKey,
      defaults: defaults
    )
    completionNotificationsEnabled = Self.preference(
      Self.completionPreferenceKey,
      defaults: defaults
    )
    failureNotificationsEnabled = Self.preference(
      Self.failurePreferenceKey,
      defaults: defaults
    )
    focusCompletionNotificationsEnabled = defaults.bool(
      forKey: Self.focusCompletionPreferenceKey
    )
    focusCompletionSoundEnabled = defaults.bool(
      forKey: Self.focusCompletionSoundPreferenceKey
    )
    super.init()
    if configuresNotificationCenter {
      UNUserNotificationCenter.current().delegate = self
    }
  }

  func setEnabled(_ enabled: Bool) {
    if !enabled {
      isEnabled = false
      isRequestingAuthorization = false
      permissionMessage = nil
      defaults.set(false, forKey: Self.preferenceKey)
      return
    }

    guard !isRequestingAuthorization else { return }
    isRequestingAuthorization = true
    permissionMessage = nil
    authorizationRequester([.alert, .sound]) { [weak self] granted, error in
      Task { @MainActor in
        guard let self else { return }
        self.isRequestingAuthorization = false
        self.isEnabled = granted
        self.defaults.set(granted, forKey: Self.preferenceKey)
        if let error {
          self.permissionMessage = error.localizedDescription
          NSLog("NotchRouter notification authorization failed: \(error)")
        } else if !granted {
          self.permissionMessage =
            "Notifications are disabled for NotchRouter in System Settings."
        }
      }
    }
  }

  func isEnabled(for kind: ActivityNotificationKind) -> Bool {
    switch kind {
    case .approval: approvalNotificationsEnabled
    case .completion: completionNotificationsEnabled
    case .failure: failureNotificationsEnabled
    }
  }

  func setEnabled(_ enabled: Bool, for kind: ActivityNotificationKind) {
    switch kind {
    case .approval:
      approvalNotificationsEnabled = enabled
      defaults.set(enabled, forKey: Self.approvalPreferenceKey)
    case .completion:
      completionNotificationsEnabled = enabled
      defaults.set(enabled, forKey: Self.completionPreferenceKey)
    case .failure:
      failureNotificationsEnabled = enabled
      defaults.set(enabled, forKey: Self.failurePreferenceKey)
    }
  }

  func setFocusCompletionNotificationsEnabled(_ enabled: Bool) {
    guard enabled != focusCompletionNotificationsEnabled else { return }
    focusCompletionNotificationsEnabled = enabled
    defaults.set(enabled, forKey: Self.focusCompletionPreferenceKey)
  }

  func setFocusCompletionSoundEnabled(_ enabled: Bool) {
    guard enabled != focusCompletionSoundEnabled else { return }
    focusCompletionSoundEnabled = enabled
    defaults.set(enabled, forKey: Self.focusCompletionSoundPreferenceKey)
  }

  func deliverFocusCompletion(durationMinutes: Int) {
    if focusCompletionSoundEnabled {
      focusCompletionSoundPlayer()
    }

    guard isEnabled, focusCompletionNotificationsEnabled else { return }

    let content = UNMutableNotificationContent()
    content.title = "Focus session complete"
    content.body = "Your \(durationMinutes)-minute focus session is complete."

    let request = UNNotificationRequest(
      identifier: "focus-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    notificationDeliverer(request)
  }

  func deliverIfImportant(_ activity: AIActivity) {
    guard isEnabled, let kind = notificationKind(for: activity.state) else {
      return
    }
    guard isEnabled(for: kind) else { return }

    let content = UNMutableNotificationContent()
    content.title = "\(activity.source): \(activity.title)"
    content.body = activity.message ?? activity.state.notificationLabel
    content.sound = .default
    if let actionURL = activity.actionURL {
      content.userInfo["action_url"] = actionURL.absoluteString
    }

    let request = UNNotificationRequest(
      identifier: "\(activity.id)-\(activity.updatedAt.timeIntervalSince1970)",
      content: content,
      trigger: nil
    )
    notificationDeliverer(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard
      let value = response.notification.request.content
        .userInfo["action_url"] as? String,
      let url = URL(string: value)
    else {
      return
    }
    _ = await MainActor.run {
      NSWorkspace.shared.open(url)
    }
  }

  private func notificationKind(
    for state: ActivityState
  ) -> ActivityNotificationKind? {
    switch state {
    case .needsApproval: .approval
    case .succeeded: .completion
    case .failed: .failure
    case .queued, .running, .stale, .cancelled: nil
    }
  }

  private static func preference(
    _ key: String,
    defaults: UserDefaults
  ) -> Bool {
    defaults.object(forKey: key) == nil
      ? true
      : defaults.bool(forKey: key)
  }
}
