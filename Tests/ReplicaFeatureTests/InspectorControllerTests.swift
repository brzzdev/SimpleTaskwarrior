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
		let task = Models.Task(
			description: "Read a book",
			id: UUID(0),
			status: .pending,
			workingSetID: 4,
		)
		let row = try #require(
			TaskRow(isBlocked: false, task: task, udaColumns: [], urgency: 0, at: now),
		)
		var state = ReplicaFeature.State(bookmark: Data(), directory: URL(filePath: "/tmp"))
		state.allRows = [row]
		let store = Store(initialState: state) { ReplicaFeature() }
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
			inspector.view.subviews.first { $0 is NSScrollView } as? NSScrollView,
		)
		let form = try #require(scrollView.documentView)

		store.send(.binding(.set(\.selection, [task.id])))
		try await wait {
			window.layoutIfNeeded()
			return form.frame.height > paneSize.height
		}

		#expect(window.frame == frame)
	}
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// Shorter than the inspector's form for a task, so the form has to scroll.
private let paneSize = NSSize(width: 270, height: 300)
