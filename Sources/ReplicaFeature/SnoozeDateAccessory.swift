import AppKit
import ComposableArchitecture
import Models
import Taskrc

/// The field under the sheet Snooze › Custom… opens, for a date in Taskwarrior's syntax, and
/// beneath it, as under the inspector's Wait, what the text resolves to as you type, or why it
/// doesn't.
final class SnoozeDateAccessory: NSStackView, NSTextFieldDelegate {
	let field = NSTextField(string: "")

	private let messageLabel = NSTextField(labelWithString: "")
	@Dependency(\.date.now) private var now
	/// Told, as the text changes, whether it resolves for every task.
	private let onChange: (_ resolves: Bool) -> Void
	private let planner: WritePlanner
	/// The properties of each task the date is for.
	private let tasks: [[String: String]]

	init(
		planner: WritePlanner,
		tasks: [[String: String]],
		onChange: @escaping (_ resolves: Bool) -> Void,
	) {
		self.onChange = onChange
		self.planner = planner
		self.tasks = tasks
		super.init(frame: NSRect(origin: .zero, size: NSSize(width: accessoryWidth, height: 0)))
		alignment = .leading
		orientation = .vertical
		spacing = 4
		field.delegate = self
		field.placeholderString = String(localized: "Date")
		messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		messageLabel.lineBreakMode = .byTruncatingTail
		setViews([field, messageLabel], in: .top)
		for view in [field, messageLabel] {
			view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
		}
		// The empty label still takes a line, so the sheet needn't grow as a message appears.
		setFrameSize(NSSize(width: accessoryWidth, height: fittingSize.height))
	}

	@available(*, unavailable)
	required init(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func controlTextDidChange(_: Notification) {
		let text = field.stringValue
		guard !text.isEmpty else {
			messageLabel.stringValue = ""
			onChange(false)
			return
		}
		do {
			let stored = try Set(tasks.map { try planner.resolve(text, for: "wait", of: $0, at: now) })
			// Text relative to a task's own dates, as in `due-1d`, can resolve differently for each.
			messageLabel.stringValue = stored.count == 1 ? preview(stored.first.flatMap(\.self)) : ""
			messageLabel.textColor = .secondaryLabelColor
			onChange(true)
		} catch {
			messageLabel.stringValue = error.localizedDescription
			messageLabel.textColor = .systemRed
			onChange(false)
		}
	}

	/// `stored` as the inspector's Wait previews it.
	private func preview(_ stored: String?) -> String {
		guard case let .date(date)? = stored.map({ UDAValue($0, as: .date) }) else {
			return ""
		}
		return date.previewText
	}
}

/// As wide as an alert's text.
private let accessoryWidth: CGFloat = 300
