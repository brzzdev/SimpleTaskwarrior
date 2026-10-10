import AppKit
import ComposableArchitecture
import Foundation
import struct Models.StoredTask
import ReplicaClient
@testable import ReplicaFeature
import Taskrc
import TaskrcClient
import Testing
import TestSupport

@MainActor
struct TaskTableControllerTests {
	@Test
	func idAndUrgencyFitTheRowsShown() async throws {
		let autosaveName = "test:\(UUID())"
		defer {
			removeAutosave(autosaveName)
		}
		let (store, table, window) = try await tableLoadingTaskrc(autosaveName: autosaveName)
		defer {
			withExtendedLifetime(window) {}
		}
		let id = try #require(table.tableColumn(withIdentifier: identifier(.id)))
		let urgency = try #require(table.tableColumn(withIdentifier: identifier(.urgency)))
		#expect(id.resizingMask.isEmpty)
		#expect(urgency.resizingMask.isEmpty)
		// An empty table fits each to its header.
		let headerWidths = (id: id.width, urgency: urgency.width)
		expectColumnsFill(table)

		// Two digits just outgrow the ID header, where an urgency of 0.0 leaves Urgency at its header.
		let narrow = (1 ... 12).map { storedTask($0, "Task \($0)", workingSetID: $0) }
		try await loadTasks(narrow, into: store, table: table)
		let narrowIDWidth = id.width
		#expect(narrowIDWidth > headerWidths.id)
		#expect(urgency.width == headerWidths.urgency)
		expectColumnsFill(table)

		let wide = storedTask(13, "Wide", workingSetID: 12_345, ["tag_wide": "", "tags": "wide"])
		try await loadTasks(narrow + [wide], into: store, table: table)
		let wideWidths = (id: id.width, urgency: urgency.width)
		#expect(wideWidths.id > narrowIDWidth)
		#expect(wideWidths.urgency > headerWidths.urgency)
		expectColumnsFill(table)

		table.sortDescriptors = [TaskSort(.id, order: .reverse).descriptor]
		try await follow(store, table: table)
		#expect(id.width == wideWidths.id)
		#expect(urgency.width == wideWidths.urgency)

		store.send(.binding(.set(\.searchText, "Task")))
		try await follow(store, table: table)
		#expect(id.width == narrowIDWidth)
		#expect(urgency.width == headerWidths.urgency)
		expectColumnsFill(table)
	}

	@Test
	func restoredLayoutDrawsColumnsInItsOrder() async throws {
		let autosaveName = "test:\(UUID())"
		defer {
			removeAutosave(autosaveName)
		}
		let (_, savingTable, _) = try await tableLoadingTaskrc(autosaveName: autosaveName)
		try #require(savingTable.tableColumn(withIdentifier: identifier(.tags))).isHidden = true
		try #require(savingTable.tableColumn(withIdentifier: identifier(.uda("size")))).isHidden = false
		savingTable.moveColumn(savingTable.column(withIdentifier: identifier(.due)), toColumn: 0)
		// Saved fitting the table, as a window saves it, so restoring it changes no column's width.
		savingTable.sizeToFit()

		let (_, restoredTable, _) = try await tableLoadingTaskrc(autosaveName: autosaveName)

		#expect(restoredTable.tableColumns.first?.identifier == identifier(.due))
		#expect(restoredTable.tableColumn(withIdentifier: identifier(.uda("size")))?.isHidden == false)
		// Where the header and cells draw: each shown column right after the one before it.
		var edge = restoredTable.rect(ofColumn: 0).minX
		for (index, column) in restoredTable.tableColumns.enumerated() {
			let rect = restoredTable.rect(ofColumn: index)
			guard !column.isHidden else {
				#expect(rect.width == 0, "\(column.identifier.rawValue)")
				continue
			}
			#expect(rect.minX == edge, "\(column.identifier.rawValue)")
			#expect(rect.width > 0, "\(column.identifier.rawValue)")
			edge = rect.maxX
		}
	}
}

/// The keys AppKit saves a table's columns and sort under, each followed by its autosave name.
private let autosaveKeyPrefixes = ["NSTableView Columns v3", "NSTableView Sort Ordering v2"]

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A Taskrc defining a UDA, and a tag whose urgency is wider than the Urgency header, attached from
/// a file so loading it doesn't offer the Taskrc hint.
private let sizedTaskrc: TaskrcClient.Loaded = {
	let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path in
		Taskrc.File(
			contents: """
				uda.size.type=string
				uda.size.values=S,M,L
				urgency.user.tag.wide.coefficient=-12345
				""",
			realPath: path,
		)
	}
	return TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
}()

private let taskrcFile = URL(filePath: "/Users/paul/.taskrc")

/// Expects the shown columns to fill the table's width exactly, so there's no gap after the last
/// and no horizontal scroller.
@MainActor
private func expectColumnsFill(
	_ table: NSTableView,
	sourceLocation: SourceLocation = #_sourceLocation,
) {
	let lastShown = table.tableColumns.lastIndex { !$0.isHidden } ?? 0
	let clipWidth = table.enclosingScrollView?.contentView.bounds.width
	#expect(table.frame.width == clipWidth, sourceLocation: sourceLocation)
	// The inset style pads the columns equally at both edges.
	#expect(
		table.bounds.width - table.rect(ofColumn: lastShown).maxX == table.rect(ofColumn: 0).minX,
		sourceLocation: sourceLocation,
	)
}

/// Waits for the table to follow the store, which it does on a later turn of the run loop.
@MainActor
private func follow(_ store: StoreOf<ReplicaFeature>, table: NSTableView) async throws {
	// The rows can change without their count changing, so this always waits out a turn.
	for _ in 0 ..< 100 {
		try await Task.sleep(for: .milliseconds(10))
		if table.numberOfRows == store.rows.count {
			break
		}
	}
	try #require(table.numberOfRows == store.rows.count)
}

private func identifier(_ column: TaskColumn) -> NSUserInterfaceItemIdentifier {
	NSUserInterfaceItemIdentifier(column.identifier)
}

@MainActor
private func loadTasks(
	_ tasks: [StoredTask],
	into store: StoreOf<ReplicaFeature>,
	table: NSTableView,
) async throws {
	store.send(.tasksLoaded(TaskSnapshot(readIndex: store.readIndex + 1, tasks: tasks)))
	try await follow(store, table: table)
}

private func removeAutosave(_ autosaveName: String) {
	for prefix in autosaveKeyPrefixes {
		UserDefaults.standard.removeObject(forKey: "\(prefix) \(autosaveName)")
	}
}

private func storedTask(
	_ seed: Int,
	_ description: String,
	workingSetID: Int,
	_ properties: [String: String] = [:],
) -> StoredTask {
	StoredTask(
		properties: properties.merging([
			"description": description,
			"entry": String(Int(now.timeIntervalSince1970)),
			"status": "pending",
		]) { $1 },
		uuid: UUID(seed).uuidString.lowercased(),
		workingSetID: workingSetID,
	)
}

/// A table laid out in a window before its Taskrc loads, as a window opening on a Replica is, once
/// the Taskrc has loaded and the table has restored its layout. The window keeps the controller,
/// and so the table's data source, alive.
@MainActor
private func tableLoadingTaskrc(
	autosaveName: String,
) async throws -> (store: StoreOf<ReplicaFeature>, table: NSTableView, window: NSWindow) {
	let store = Store(initialState: ReplicaFeature.State(bookmark: Data())) {
		ReplicaFeature()
	} withDependencies: {
		$0.date.now = now
		$0.timeZone = .gmt
	}
	let controller = TaskTableController(autosaveName: autosaveName, store: store)
	let window = NSWindow(
		contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
		styleMask: [.titled],
		backing: .buffered,
		defer: false,
	)
	window.contentViewController = controller
	// Setting the controller sized the window to its view, which starts empty.
	window.setContentSize(NSSize(width: 900, height: 400))
	window.layoutIfNeeded()
	let scrollView = try #require(controller.view as? NSScrollView)
	let table = try #require(scrollView.documentView as? NSTableView)
	store.send(.taskrcLoaded(sizedTaskrc))
	// The table follows the store on a later turn of the run loop.
	for _ in 0 ..< 100 where table.autosaveName == nil {
		await Task.yield()
	}
	try #require(table.autosaveName != nil)
	return (store, table, window)
}
