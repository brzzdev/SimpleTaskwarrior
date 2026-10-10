import Testing

/// Waits for `condition`, such as a view following the store, which it does on a later turn of the
/// run loop.
@MainActor
func wait(
	until condition: () -> Bool,
	sourceLocation: SourceLocation = #_sourceLocation,
) async throws {
	for _ in 0 ..< 100 where !condition() {
		try await Task.sleep(for: .milliseconds(10))
	}
	try #require(condition(), sourceLocation: sourceLocation)
}
