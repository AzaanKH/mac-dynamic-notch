import Combine
import Foundation

enum FocusTimerPhase: String, Codable, Sendable {
  case idle
  case running
  case paused
  case completed
}

enum FocusTimerPresentationEvent: Equatable, Sendable {
  case stateChanged
  case completed
}

@MainActor
final class FocusTimerController: ObservableObject {
  static let defaultDurationMinutes = 25
  static let presetDurations = [15, 25, 50]
  static let tickInterval: Duration = .seconds(1)

  @Published private(set) var phase: FocusTimerPhase = .idle
  @Published private(set) var selectedDurationMinutes = defaultDurationMinutes
  @Published private(set) var durationSeconds: TimeInterval =
    TimeInterval(defaultDurationMinutes * 60)
  @Published private(set) var remainingSeconds: TimeInterval =
    TimeInterval(defaultDurationMinutes * 60)

  var onChange: ((FocusTimerPresentationEvent) -> Void)?

  var isPresented: Bool {
    phase != .idle
  }

  var progress: Double {
    guard durationSeconds > 0 else { return 0 }
    return min(max(1 - remainingSeconds / durationSeconds, 0), 1)
  }

  var formattedRemaining: String {
    let wholeSeconds = max(Int(ceil(remainingSeconds)), 0)
    return String(
      format: "%02d:%02d",
      wholeSeconds / 60,
      wholeSeconds % 60
    )
  }

  var stateLabel: String {
    switch phase {
    case .idle: "Ready to focus"
    case .running: "Focus in progress"
    case .paused: "Paused"
    case .completed: "Focus complete"
    }
  }

  private static let persistenceKey = "focusTimerState"
  private static let maximumDurationMinutes = 180

  private let defaults: UserDefaults
  private let nowProvider: () -> Date
  private let ticksAutomatically: Bool
  private var targetDate: Date?
  private var ticker: Task<Void, Never>?

  init(
    defaults: UserDefaults = .standard,
    nowProvider: @escaping () -> Date = Date.init,
    ticksAutomatically: Bool = true
  ) {
    self.defaults = defaults
    self.nowProvider = nowProvider
    self.ticksAutomatically = ticksAutomatically
    restore()
    refresh()
    if phase == .running {
      beginTicking()
    }
  }

  func selectDuration(minutes: Int) {
    guard phase == .idle else { return }
    let clampedMinutes = min(
      max(minutes, 1),
      Self.maximumDurationMinutes
    )
    selectedDurationMinutes = clampedMinutes
    durationSeconds = TimeInterval(clampedMinutes * 60)
    remainingSeconds = durationSeconds
    persist()
  }

  func start() {
    durationSeconds = TimeInterval(selectedDurationMinutes * 60)
    remainingSeconds = durationSeconds
    targetDate = nowProvider().addingTimeInterval(remainingSeconds)
    phase = .running
    persist()
    beginTicking()
    onChange?(.stateChanged)
  }

  func pause() {
    guard phase == .running else { return }
    refresh()
    guard phase == .running else { return }
    targetDate = nil
    phase = .paused
    ticker?.cancel()
    ticker = nil
    persist()
    onChange?(.stateChanged)
  }

  func resume() {
    guard phase == .paused, remainingSeconds > 0 else { return }
    targetDate = nowProvider().addingTimeInterval(remainingSeconds)
    phase = .running
    persist()
    beginTicking()
    onChange?(.stateChanged)
  }

  func addFiveMinutes() {
    guard phase == .running || phase == .paused else { return }
    if phase == .running {
      refresh()
    }
    guard phase == .running || phase == .paused else { return }

    let maximumSeconds = TimeInterval(Self.maximumDurationMinutes * 60)
    let addedSeconds = min(300, maximumSeconds - durationSeconds)
    guard addedSeconds > 0 else { return }

    durationSeconds += addedSeconds
    remainingSeconds += addedSeconds
    if phase == .running {
      targetDate = nowProvider().addingTimeInterval(remainingSeconds)
    }
    persist()
    onChange?(.stateChanged)
  }

  func reset() {
    ticker?.cancel()
    ticker = nil
    targetDate = nil
    phase = .idle
    durationSeconds = TimeInterval(selectedDurationMinutes * 60)
    remainingSeconds = durationSeconds
    persist()
    onChange?(.stateChanged)
  }

  func refresh() {
    guard phase == .running, let targetDate else { return }
    let updatedRemaining = max(
      targetDate.timeIntervalSince(nowProvider()),
      0
    )
    remainingSeconds = updatedRemaining

    if updatedRemaining <= 0 {
      complete()
    }
  }

  private func complete() {
    ticker?.cancel()
    ticker = nil
    targetDate = nil
    remainingSeconds = 0
    phase = .completed
    persist()
    onChange?(.completed)
  }

  private func beginTicking() {
    guard ticksAutomatically else { return }
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.tickInterval)
        } catch {
          return
        }
        guard let self else { return }
        self.refresh()
      }
    }
  }

  private func restore() {
    guard
      let data = defaults.data(forKey: Self.persistenceKey),
      let snapshot = try? JSONDecoder().decode(
        FocusTimerSnapshot.self,
        from: data
      )
    else { return }

    selectedDurationMinutes = min(
      max(snapshot.selectedDurationMinutes, 1),
      Self.maximumDurationMinutes
    )
    durationSeconds = min(
      max(snapshot.durationSeconds, 60),
      TimeInterval(Self.maximumDurationMinutes * 60)
    )
    remainingSeconds = min(
      max(snapshot.remainingSeconds, 0),
      durationSeconds
    )
    targetDate = snapshot.targetDate
    phase = snapshot.phase

    if phase == .running, targetDate == nil {
      phase = .paused
    } else if phase == .idle {
      durationSeconds = TimeInterval(selectedDurationMinutes * 60)
      remainingSeconds = durationSeconds
      targetDate = nil
    } else if phase == .completed {
      remainingSeconds = 0
      targetDate = nil
    }
  }

  private func persist() {
    let snapshot = FocusTimerSnapshot(
      phase: phase,
      selectedDurationMinutes: selectedDurationMinutes,
      durationSeconds: durationSeconds,
      remainingSeconds: remainingSeconds,
      targetDate: targetDate
    )
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: Self.persistenceKey)
  }
}

private struct FocusTimerSnapshot: Codable {
  let phase: FocusTimerPhase
  let selectedDurationMinutes: Int
  let durationSeconds: TimeInterval
  let remainingSeconds: TimeInterval
  let targetDate: Date?
}
