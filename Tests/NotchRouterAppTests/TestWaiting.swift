/// Polls `condition` until it holds or `timeout` elapses, returning whether it
/// held. Tests use the result to fail and clean up instead of hanging.
func waitUntil(
  isolation: isolated (any Actor)? = #isolation,
  timeout: Duration = .seconds(2),
  _ condition: () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return await condition()
}
