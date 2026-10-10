#if DEBUG
import AppKit
import Network
import ReplicaFeature

/// Drives the app for `headless.py` without the real cursor or keyboard: a line of JSON in on the
/// Unix socket at `STW_DRIVER_SOCKET`, a line of JSON out. Each command acts on the app's objects
/// directly, so the app is never activated and nothing passes through the window server's input.
///
/// The app is never active, so it has no key window, and AppKit resolves menu targets, key
/// equivalents and first responders through the key window. `perform` and `click` stand in for
/// it, from the Replica window.
@MainActor
final class DebugDriver {
	/// The other half is `request` in `headless.py`, which builds each one from the command line.
	enum Command: Decodable {
		case choose(path: String)
		case click(row: Int, column: String?)
		/// The header's menu, or with `row` the table's menu on that row.
		case contextMenu(item: String, row: Int?)
		case dump
		case frame(width: Double, height: Double)
		case key(characters: String, modifiers: [Modifier])
		case menu(menu: String, item: String)
		case open(path: String)
		case quit
		case sheet(button: String)
		case shot(path: String)
		case type(text: String)
	}

	enum Modifier: String, Decodable {
		case command
		case control
		case option
		case shift

		var flag: NSEvent.ModifierFlags {
			switch self {
			case .command: .command
			case .control: .control
			case .option: .option
			case .shift: .shift
			}
		}
	}

	struct Failure: Error, CustomStringConvertible {
		let description: String

		init(_ description: String) {
			self.description = description
		}
	}

	struct Reply: Encodable {
		var dump: Dump?
		var error: String?
	}

	/// The socket to listen on, at most 103 bytes: `sockaddr_un` holds no more. With it set, the
	/// app hides every window it shows, so a driven instance never covers the screen of whoever
	/// is at the Mac.
	static let socketPath = ProcessInfo.processInfo.environment["STW_DRIVER_SOCKET"]

	/// Actions that bring another app forward, over whatever the person at the Mac is doing.
	private static let foregroundingActions: Set<Selector> = [
		#selector(ReplicaWindowController.revealInFinder(_:)),
	]
	/// The key codes of the keys whose characters say nothing of the key: AppKit reads the code for
	/// these. Every other key is sent with code 0.
	private static let keyCodes: [String: UInt16] = [
		"\r": 36,
		"\t": 48,
		"\u{7F}": 51,
		"\u{1B}": 53,
	]
	/// How long `open` waits for the Replica to load before replying with an empty table.
	private static let loadTimeout = Duration.seconds(2)
	/// How long a command waits for the store's effects, and the view updates they cause, to land
	/// before its dump.
	private static let settleDelay = Duration.milliseconds(300)

	private let listener: NWListener
	private let openWindow: (URL) async throws -> NSWindow?
	private var windowObserver: (any NSObjectProtocol)?

	init?(openWindow: @escaping (URL) async throws -> NSWindow?) {
		guard let path = Self.socketPath else {
			return nil
		}
		unlink(path)
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .unix(path: path)
		guard let listener = try? NWListener(using: parameters) else {
			return nil
		}
		self.listener = listener
		self.openWindow = openWindow
		listener.newConnectionHandler = { [weak self] connection in
			MainActor.assumeIsolated {
				connection.start(queue: .main)
				self?.receive(on: connection, buffer: Data())
			}
		}
		listener.start(queue: .main)
		// After every pass of the event loop, so a window is hidden before it first draws: Replica
		// windows, their sheets and alerts alike.
		windowObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didUpdateNotification,
			object: nil,
			queue: .main,
		) { _ in
			MainActor.assumeIsolated {
				for window in NSApp.windows where !window.ignoresMouseEvents {
					window.alphaValue = 0
					window.ignoresMouseEvents = true
				}
			}
		}
	}

	/// Runs a click without its tracking loop blocking the driver: the loop waits for a mouse-up,
	/// so the up is queued before the down is sent. A window that isn't key doesn't hand its first
	/// responder to the view clicked, so that's done here, as a key window would.
	private func click(_ point: NSPoint, in window: NSWindow) {
		if
			let hit = window.contentView?.superview?.hitTest(point),
			let responder = sequence(first: hit, next: \.superview).first(where: \.acceptsFirstResponder)
		{
			window.makeFirstResponder(responder)
		}
		NSApp.postEvent(mouse(.leftMouseUp, at: point, in: window), atStart: false)
		window.sendEvent(mouse(.leftMouseDown, at: point, in: window))
	}

	/// Sends a key to `window`. A menu's key equivalent resolves its target as choosing the item
	/// does, so it's performed the same way.
	/// The target `item`'s action goes to, found from `window` as AppKit would were it key: from the
	/// view a context menu belongs to, or else the first responder. Nil when nothing handles the
	/// action or the target disables the item, which AppKit treats alike.
	private func enabledTarget(
		for item: NSMenuItem,
		in window: NSWindow,
		from view: NSView? = nil,
	) -> AnyObject? {
		guard let action = item.action else {
			return nil
		}
		let chain = sequence(first: view ?? window.firstResponder, next: { $0?.nextResponder })
			.compactMap { $0 as AnyObject? }
		let candidates = chain + [window.windowController, window.delegate, NSApp, NSApp.delegate]
			.compactMap { $0 as AnyObject? }
		guard let target = item.target ?? candidates.first(where: { $0.responds(to: action) }) else {
			return nil
		}
		let isEnabled = (target as? any NSMenuItemValidation)?.validateMenuItem(item)
			?? (target as? any NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
			?? true
		return isEnabled ? target : nil
	}

	private func key(_ characters: String, _ modifiers: [Modifier], in window: NSWindow) throws {
		let flags = NSEvent.ModifierFlags(modifiers.map(\.flag))
		// The Delete key types U+007F, which a menu names as backspace, U+0008.
		func typed(_ key: String) -> String {
			key == "\u{8}" ? "\u{7F}" : key
		}
		let characters = typed(characters)
		// An uppercase key equivalent implies Shift.
		let item = menuItems(in: NSApp.mainMenu).first { item in
			let isShifted = item.keyEquivalent != item.keyEquivalent.lowercased()
			return typed(item.keyEquivalent).lowercased() == characters.lowercased()
				&& item.keyEquivalentModifierMask.union(isShifted ? .shift : []) == flags
		}
		// A disabled key equivalent goes on to the first responder, as AppKit sends it: ⌘⌫ deletes
		// text in a field being edited, where it isn't the task Delete.
		if let item, let target = enabledTarget(for: item, in: window) {
			try send(item, to: target)
			return
		}
		guard
			let event = NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: flags,
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: Self.keyCodes[characters] ?? 0,
			)
		else {
			throw Failure("can't make a key event")
		}
		if !window.performKeyEquivalent(with: event) {
			window.sendEvent(event)
		}
	}

	private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
		// Only nil for a type that isn't a mouse event.
		// swiftlint:disable:next force_unwrapping
		NSEvent.mouseEvent(
			with: type,
			location: point,
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: 1,
			pressure: 1,
		)!
	}

	/// Runs `body` on the Replica window, then replies with the window once it settles.
	private func onWindow(_ body: (NSWindow) throws -> Void) async throws -> Reply {
		let window = try replicaWindow()
		try body(window)
		try await Task.sleep(for: Self.settleDelay)
		return Reply(dump: Dump(window))
	}

	/// Validates and performs `item`, as choosing it from the menu would.
	private func perform(
		_ item: NSMenuItem,
		in window: NSWindow,
		from view: NSView? = nil,
	) throws {
		guard let target = enabledTarget(for: item, in: window, from: view) else {
			throw Failure("\(item.title) is disabled")
		}
		try send(item, to: target)
	}

	private func receive(on connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, _ in
			MainActor.assumeIsolated {
				let buffer = buffer + (data ?? Data())
				guard let end = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
					if done {
						connection.cancel()
					} else {
						self.receive(on: connection, buffer: buffer)
					}
					return
				}
				Task {
					let reply = await self.reply(to: buffer[..<end])
					var line = (try? JSONEncoder().encode(reply)) ?? Data()
					line.append(UInt8(ascii: "\n"))
					connection.send(content: line, completion: .contentProcessed { _ in
						connection.cancel()
					})
				}
			}
		}
	}

	/// The window commands act on. Each agent runs its own instance, so it's the only one.
	private func replicaWindow() throws -> NSWindow {
		let prefix = AppDelegate.replicaWindowPrefix
		guard
			let window = NSApp.orderedWindows.first(where: {
				$0.identifier?.rawValue.hasPrefix(prefix) == true
			})
		else {
			throw Failure("no Replica window")
		}
		return window
	}

	private func reply(to line: Data) async -> Reply {
		do {
			return try await run(JSONDecoder().decode(Command.self, from: line))
		} catch {
			return Reply(error: String(describing: error))
		}
	}

	private func run(_ command: Command) async throws -> Reply {
		switch command {
		case let .choose(path):
			PanelOverride.next = URL(filePath: path)
			return Reply()

		case let .click(row, column):
			return try await onWindow { window in
				let table = try table(in: window)
				let index = try column.map { identifier in
					let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
					guard index >= 0 else {
						throw Failure("no column \(identifier)")
					}
					return index
				} ?? 0
				let cell = table.frameOfCell(atColumn: index, row: row)
				click(table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil), in: window)
			}

		case let .contextMenu(item, row):
			return try await onWindow { window in
				let table = try table(in: window)
				let view: NSView
				let point: NSPoint
				if let row {
					view = table
					let rect = table.rect(ofRow: row)
					point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
				} else {
					view = try table.headerView ?? { throw Failure("the table has no header") }()
					point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
				}
				guard let menu = view.menu(for: mouse(.rightMouseDown, at: point, in: window)) else {
					throw Failure("no context menu")
				}
				menu.delegate?.menuNeedsUpdate?(menu)
				guard let match = menu.item(withTitle: item) else {
					throw Failure("no item \(item)")
				}
				try perform(match, in: window, from: view)
			}

		case .dump:
			return try Reply(dump: Dump(replicaWindow()))

		case let .frame(width, height):
			return try await onWindow { window in
				window.setContentSize(NSSize(width: width, height: height))
			}

		case let .key(characters, modifiers):
			return try await onWindow { window in
				try key(characters, modifiers, in: window)
			}

		case let .menu(menu, item):
			return try await onWindow { window in
				guard let match = NSApp.mainMenu?.item(withTitle: menu)?.submenu?.item(withTitle: item)
				else {
					throw Failure("no item \(menu) > \(item)")
				}
				try perform(match, in: window)
			}

		case let .open(path):
			// Its window, so the dump isn't of another Replica's window in front.
			let url = URL(filePath: path, directoryHint: .isDirectory)
			guard let window = try await openWindow(url) else {
				throw Failure("no window for \(path)")
			}
			// The table fills once the Replica loads; an empty Replica waits out the timeout.
			let table = try table(in: window)
			let deadline = ContinuousClock.now + Self.loadTimeout
			while table.numberOfRows == 0, ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(50))
			}
			return Reply(dump: Dump(window))

		case .quit:
			// After the reply goes out.
			Task {
				NSApp.terminate(nil)
			}
			return Reply()

		case let .sheet(button):
			return try await onWindow { window in
				guard let sheet = window.attachedSheet else {
					throw Failure("no sheet")
				}
				let buttons = descendants(of: sheet.contentView).compactMap { $0 as? NSButton }
				guard let match = buttons.first(where: { $0.title == button }) else {
					throw Failure("no button \(button)")
				}
				match.performClick(nil)
			}

		case let .shot(path):
			let window = try replicaWindow()
			let frameView = try window.contentView?.superview ?? { throw Failure("no frame view") }()
			guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
				throw Failure("can't render the window")
			}
			frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
			try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
			return Reply(dump: Dump(window))

		case let .type(text):
			return try await onWindow { window in
				guard let client = window.firstResponder as? any NSTextInputClient else {
					throw Failure("the first responder takes no text")
				}
				client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
			}
		}
	}

	/// Sends `item`'s action to `target`, unless it would bring another app forward: no window of
	/// this one can hide that.
	private func send(_ item: NSMenuItem, to target: AnyObject) throws {
		guard let action = item.action else {
			return
		}
		guard !Self.foregroundingActions.contains(action) else {
			throw Failure("\(item.title) brings another app forward; check it with driver.sh")
		}
		NSApp.sendAction(action, to: target, from: item)
	}

	private func table(in window: NSWindow) throws -> NSTableView {
		guard let table = tableViews(in: window).first(where: { !($0 is NSOutlineView) }) else {
			throw Failure("no task table")
		}
		return table
	}
}

/// What the window shows, as text, so an agent can check it without a screenshot.
struct Dump: Encodable {
	struct Column: Encodable {
		let identifier: String
		let title: String
		let width: Double
	}

	struct Sheet: Encodable {
		let buttons: [String]
		let text: [String]
	}

	struct Table: Encodable {
		enum Kind: String, Encodable {
			case outline
			case table
		}

		let columns: [Column]
		let kind: Kind
		let rows: [[String]]
		let selectedRows: [Int]
	}

	let firstResponder: String
	let sheet: Sheet?
	let tables: [Table]
	let title: String

	@MainActor
	init(_ window: NSWindow) {
		firstResponder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
		sheet = window.attachedSheet.map { sheet in
			let views = descendants(of: sheet.contentView)
			return Sheet(
				buttons: views.compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty },
				text: views.compactMap { view in
					guard let field = view as? NSTextField, !(view.superview is NSButton) else {
						return nil
					}
					return field.stringValue.isEmpty ? nil : field.stringValue
				},
			)
		}
		tables = tableViews(in: window).map { table in
			// Indexed in `tableColumns`, which is how a cell's view is asked for.
			let columns = table.tableColumns.enumerated().filter { !$0.element.isHidden }
			return Table(
				columns: columns.map { _, column in
					Column(
						identifier: column.identifier.rawValue,
						title: column.title,
						width: column.width,
					)
				},
				kind: table is NSOutlineView ? .outline : .table,
				rows: (0 ..< table.numberOfRows).map { row in
					columns.map { index, _ in
						let cell = table.view(atColumn: index, row: row, makeIfNecessary: true)
						return descendants(of: cell)
							.filter { !$0.isHiddenOrHasHiddenAncestor }
							.compactMap { ($0 as? NSTextField)?.stringValue }
							.filter { !$0.isEmpty }
							.joined(separator: " ")
					}
				},
				selectedRows: Array(table.selectedRowIndexes),
			)
		}
		title = window.title
	}
}

@MainActor
private func descendants(of view: NSView?) -> [NSView] {
	guard let view else {
		return []
	}
	return [view] + view.subviews.flatMap(descendants)
}

@MainActor
private func menuItems(in menu: NSMenu?) -> [NSMenuItem] {
	(menu?.items ?? []).flatMap { [$0] + menuItems(in: $0.submenu) }
}

/// The window's tables, the sidebar's outline included.
@MainActor
private func tableViews(in window: NSWindow) -> [NSTableView] {
	descendants(of: window.contentView).compactMap { $0 as? NSTableView }
}
#endif
