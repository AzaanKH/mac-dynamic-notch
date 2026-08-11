import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKey {
  enum RegistrationError: LocalizedError {
    case installingHandler(OSStatus)
    case registeringShortcut(OSStatus)

    var errorDescription: String? {
      switch self {
      case .installingHandler(let status):
        "Could not install the global shortcut handler (OSStatus \(status))."
      case .registeringShortcut(let status):
        "Could not register the global shortcut (OSStatus \(status))."
      }
    }
  }

  private static let signature: OSType = 0x4E_52_54_52 // "NRTR"

  nonisolated(unsafe) private var eventHandler: EventHandlerRef?
  nonisolated(unsafe) private var hotKey: EventHotKeyRef?
  private let action: @MainActor () -> Void

  init(
    keyCode: UInt32,
    modifiers: UInt32,
    action: @escaping @MainActor () -> Void
  ) throws {
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let shortcut = Unmanaged<GlobalHotKey>
          .fromOpaque(context)
          .takeUnretainedValue()
        MainActor.assumeIsolated {
          shortcut.action()
        }
        return noErr
      },
      1,
      &eventType,
      context,
      &eventHandler
    )
    guard handlerStatus == noErr else {
      throw RegistrationError.installingHandler(handlerStatus)
    }

    let identifier = EventHotKeyID(
      signature: Self.signature,
      id: 1
    )
    let registrationStatus = RegisterEventHotKey(
      keyCode,
      modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard registrationStatus == noErr else {
      if let eventHandler {
        RemoveEventHandler(eventHandler)
        self.eventHandler = nil
      }
      throw RegistrationError.registeringShortcut(registrationStatus)
    }
  }

  deinit {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }
}
