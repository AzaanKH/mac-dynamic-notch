import AudioToolbox
import Combine
import CoreAudio
import SwiftUI

@MainActor
final class SystemVolumeController: ObservableObject {
  @Published private(set) var level: Double = 0
  @Published private(set) var isMuted = false
  @Published private(set) var isAvailable = false

  private var observedDevice = AudioDeviceID(kAudioObjectUnknown)
  private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
  private var volumeListener: AudioObjectPropertyListenerBlock?
  private var muteListener: AudioObjectPropertyListenerBlock?
  private var lastAudibleLevel = 0.5

  init() {
    refresh()
    observeDefaultOutputDevice()
  }

  var effectiveLevel: Double {
    isMuted ? 0 : level
  }

  var symbolName: String {
    guard isAvailable else { return "speaker.badge.exclamationmark.fill" }
    switch effectiveLevel {
    case ...0.001: return "speaker.slash.fill"
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
  }

  func refresh() {
    let device = Self.defaultOutputDevice()
    guard device != kAudioObjectUnknown else {
      isAvailable = false
      return
    }

    if observedDevice != device {
      observeVolumeChanges(on: device)
    }

    guard let currentLevel = Self.readVolume(from: device) else {
      isAvailable = false
      return
    }

    level = Double(currentLevel).clamped(to: 0...1)
    isMuted = Self.readMute(from: device) ?? false
    isAvailable = true
    if level > 0.001 {
      lastAudibleLevel = level
    }
  }

  func setLevel(_ newLevel: Double) {
    guard isAvailable, observedDevice != kAudioObjectUnknown else { return }
    let clampedLevel = newLevel.clamped(to: 0...1)

    if isMuted, clampedLevel > 0 {
      _ = Self.writeMute(false, to: observedDevice)
      isMuted = false
    }

    guard Self.writeVolume(Float32(clampedLevel), to: observedDevice) else {
      refresh()
      return
    }
    level = clampedLevel
    if clampedLevel > 0.001 {
      lastAudibleLevel = clampedLevel
    }
  }

  func toggleMute() {
    guard isAvailable, observedDevice != kAudioObjectUnknown else { return }
    if Self.writeMute(!isMuted, to: observedDevice) {
      isMuted.toggle()
      return
    }

    if effectiveLevel > 0.001 {
      lastAudibleLevel = level
      setLevel(0)
    } else {
      setLevel(max(lastAudibleLevel, 0.25))
    }
  }

  private func observeDefaultOutputDevice() {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.refresh()
      }
    }
    guard
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        listener
      ) == noErr
    else { return }
    defaultDeviceListener = listener
  }

  private func observeVolumeChanges(on device: AudioDeviceID) {
    stopObservingVolumeChanges()
    observedDevice = device

    var volumeAddress = Self.volumeAddress
    if AudioObjectHasProperty(device, &volumeAddress) {
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.refresh()
        }
      }
      if AudioObjectAddPropertyListenerBlock(
        device,
        &volumeAddress,
        .main,
        listener
      ) == noErr {
        volumeListener = listener
      }
    }

    var muteAddress = Self.muteAddress
    if AudioObjectHasProperty(device, &muteAddress) {
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.refresh()
        }
      }
      if AudioObjectAddPropertyListenerBlock(
        device,
        &muteAddress,
        .main,
        listener
      ) == noErr {
        muteListener = listener
      }
    }
  }

  private func stopObservingVolumeChanges() {
    guard observedDevice != kAudioObjectUnknown else { return }

    if let volumeListener {
      var address = Self.volumeAddress
      AudioObjectRemovePropertyListenerBlock(
        observedDevice,
        &address,
        .main,
        volumeListener
      )
      self.volumeListener = nil
    }

    if let muteListener {
      var address = Self.muteAddress
      AudioObjectRemovePropertyListenerBlock(
        observedDevice,
        &address,
        .main,
        muteListener
      )
      self.muteListener = nil
    }
  }

  private static var volumeAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static var muteAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func defaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    )
    return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
  }

  private static func readVolume(from device: AudioDeviceID) -> Float32? {
    var address = volumeAddress
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard
      AudioObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        &size,
        &value
      ) == noErr
    else { return nil }
    return value
  }

  private static func writeVolume(
    _ volume: Float32,
    to device: AudioDeviceID
  ) -> Bool {
    var address = volumeAddress
    guard AudioObjectHasProperty(device, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard
      AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
      settable.boolValue
    else { return false }
    var value = volume
    return AudioObjectSetPropertyData(
      device,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<Float32>.size),
      &value
    ) == noErr
  }

  private static func readMute(from device: AudioDeviceID) -> Bool? {
    var address = muteAddress
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard
      AudioObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        &size,
        &value
      ) == noErr
    else { return nil }
    return value != 0
  }

  private static func writeMute(
    _ muted: Bool,
    to device: AudioDeviceID
  ) -> Bool {
    var address = muteAddress
    guard AudioObjectHasProperty(device, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard
      AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
      settable.boolValue
    else { return false }
    var value: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(
      device,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<UInt32>.size),
      &value
    ) == noErr
  }
}

struct SystemVolumeSlider: View {
  @ObservedObject var controller: SystemVolumeController
  var showsPercentage = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 7) {
      Button(action: controller.toggleMute) {
        Image(systemName: controller.symbolName)
          .font(.callout.weight(.semibold))
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 32, height: 32)
          .background(
            .white.opacity(contrast == .increased ? 0.14 : 0.075),
            in: Circle()
          )
          .overlay {
            Circle()
              .strokeBorder(
                .white.opacity(contrast == .increased ? 0.75 : 0.08),
                lineWidth: contrast == .increased ? 1.5 : 0.5
              )
          }
      }
      .buttonStyle(.plain)
      .focusable()
      .dashboardTint(controller.isAvailable ? .white.opacity(0.78) : .orange)
      .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")

      Slider(
        value: Binding(
          get: { controller.level },
          set: { controller.setLevel($0) }
        ),
        in: 0...1
      )
      .focusable(interactions: .edit)
      .controlSize(.regular)
      .tint(.white.opacity(contrast == .increased ? 1 : 0.88))
      .disabled(!controller.isAvailable)
      .accessibilityLabel("System volume")
      .accessibilityValue(
        controller.isMuted
          ? "Muted, \(Int(controller.level * 100)) percent"
          : "\(Int(controller.level * 100)) percent"
      )

      if showsPercentage {
        Text("\(Int(controller.level * 100))%")
          .font(.caption.monospacedDigit())
          .dashboardTertiaryText()
          .frame(width: 38, alignment: .trailing)
      }
    }
    .frame(minHeight: 32)
    .onAppear(perform: controller.refresh)
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
