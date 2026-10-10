import AppKit
import ComposableArchitecture
import Foundation
import Models
@testable import ReplicaFeature
import Testing

@MainActor
struct InspectorControllerTests {
	@Test
	func selectingATaskTallerThanThePaneKeepsTheWindowsFrame() async throws {
		let now = Date(timeIntervalSince1970: 1_790_000_000)
		var task = Models.Task(
			description: "Read a book",
			id: UUID(0),
			status: .pending,
			workingSetID: 4,
		)
		task.annotations = [
			Models.Task.Annotation(description: "Chapter 1", entry: now),
			Models.Task.Annotation(description: "Chapter 2", entry: now),
		]
		let row = try #require(
			TaskRow(isBlocked: false, task: task, udaColumns: [], urgency: 0, at: now),
		)
		var state = ReplicaFeature.State(bookmark: Data())
		state.allRows = [row]
		state.directory = URL(filePath: "/Users/paul/.task", directoryHint: .isDirectory)
		state.rows = [row]
		let store = Store(initialState: state) {
			ReplicaFeature()
		} withDependencies: {
			$0.date.now = now
			$0.timeZone = .gmt
		}
		let inspector = InspectorController(store: store)
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: paneSize),
			styleMask: [.resizable, .titled],
			backing: .buffered,
			defer: false,
		)
		window.contentViewController = inspector
		// Setting the controller sized the window to its view, which starts empty.
		window.setContentSize(paneSize)
		window.layoutIfNeeded()
		let frame = window.frame
		let scrollView = try #require(
			inspector.view.subviews.lazy.compactMap { $0 as? NSScrollView }.first,
		)
		let form = try #require(scrollView.documentView)

		store.send(.binding(.set(\.selection, [task.id])))
		// The inspector shows the task on a later turn of the run loop.
		for _ in 0 ..< 100 where form.frame.height <= paneSize.height {
			try await _Concurrency.Task.sleep(for: .milliseconds(10))
			window.layoutIfNeeded()
		}

		try #require(form.frame.height > paneSize.height)
		#expect(window.frame == frame)
	}
}

/// Shorter than the inspector's form for a task with annotations, so the form has to scroll.
private let paneSize = NSSize(width: 270, height: 300)
