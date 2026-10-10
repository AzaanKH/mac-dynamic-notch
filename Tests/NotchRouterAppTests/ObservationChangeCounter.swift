import Observation

/// Counts how often the observable properties read by `track` are set. Like a
/// view, it re-arms after every change so later writes are counted too.
@MainActor
final class ObservationChangeCounter {
  private(set) var count = 0
  private let track: @MainActor () -> Void

  init(_ track: @escaping @MainActor () -> Void) {
    self.track = track
    arm()
  }

  private func arm() {
    withObservationTracking(track) { [weak self] in
      // Called synchronously from the setter, which runs on the main actor.
      MainActor.assumeIsolated {
        guard let self else { return }
        self.count += 1
        self.arm()
      }
    }
  }
}
