// The sidebar: fixed views, the project tree and tags, which narrow the table, over the Context.
import AppKit
import ComposableArchitecture
import SwiftNavigation
import Taskrc

/// A source list of the store's sidebar, which sends back its selection and the tags it hides, and
/// a footer naming the active Context.
final class SidebarController: NSViewController, NSGestureRecognizerDelegate, NSMenuDelegate,
	NSOutlineViewDataSource, NSOutlineViewDelegate
{
	private let contextFooter = NSStackView()
	private let contextLabel = truncatingLabel()
	/// Kept here, since a reload makes new nodes and forgets which were expanded.
	private var expandedProjects: Set<String> = []
	/// Set while the outline follows the store, so the changes it makes aren't sent back.
	private var isFollowingStore = false
	private var nodes: [SidebarNode] = []
	private let outline = NSOutlineView()
	private var sidebar: Sidebar?
	private let store: StoreOf<ReplicaFeature>

	init(store: StoreOf<ReplicaFeature>) {
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let view = NSView()
		let scrollView = NSScrollView()
		scrollView.documentView = outline
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		let info = NSButton(
			image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!,
			target: self,
			action: #selector(contextInfoButtonClicked(_:)),
		)
		info.isBordered = false
		info.setAccessibilityLabel(String(localized: "About the Context"))
		contextLabel.textColor = .secondaryLabelColor
		contextFooter.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
		contextFooter.setViews([contextLabel, info], in: .leading)
		for subview in [contextFooter, scrollView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		NSLayoutConstraint.activate([
			contextFooter.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			contextFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			contextFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: contextFooter.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		let column = NSTableColumn()
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.allowsEmptySelection = true
		outline.allowsMultipleSelection = true
		outline.floatsGroupRows = false
		outline.headerView = nil
		outline.rowSizeStyle = .default
		outline.style = .sourceList
		outline.dataSource = self
		outline.delegate = self
		outline.menu = NSMenu()
		outline.menu?.delegate = self
		let optionClick = NSClickGestureRecognizer(
			target: self,
			action: #selector(tagOptionClicked(_:)),
		)
		// So the outline never sees an ⌥-click on a tag, and selects nothing.
		optionClick.delaysPrimaryMouseButtonEvents = true
		optionClick.delegate = self
		outline.addGestureRecognizer(optionClick)

		observe { [weak self] in
			self?.updateOutline()
		}
		observe { [weak self] in
			guard let self else {
				return
			}
			let context = store.activeContext
			contextFooter.isHidden = context == nil
			contextLabel.stringValue = context.map { String(localized: "Context: \($0)") } ?? ""
		}
	}

	@objc
	func contextInfoButtonClicked(_ sender: NSButton) {
		let label = WrappingLabel(wrappingLabelWithString: contextSummary(
			skipped: store.runningTaskrc.contextWrite.skipped,
		))
		label.translatesAutoresizingMaskIntoConstraints = false
		let content = NSView()
		content.addSubview(label)
		NSLayoutConstraint.activate([
			label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
			label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
			label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
			label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
			label.widthAnchor.constraint(equalToConstant: contextPopoverWidth),
		])
		let controller = NSViewController()
		controller.view = content
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = controller
		// Above the button, which sits at the window's bottom. A button is flipped, so that's `minY`.
		popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
	}

	@objc
	func hiddenTagMenuItemChosen(_ sender: NSMenuItem) {
		guard let tag = sender.representedObject as? String else {
			return
		}
		store.send(.hiddenTagToggled(tag))
	}

	/// Takes up a click only with ⌥ down and on a tag. Each click of an ⌥-double-click starts a
	/// stream of its own, and a second would undo the first.
	func gestureRecognizer(
		_: NSGestureRecognizer,
		shouldAttemptToRecognizeWith event: NSEvent,
	) -> Bool {
		guard event.modifierFlags.contains(.option), event.clickCount == 1 else {
			return false
		}
		let point = outline.convert(event.locationInWindow, from: nil)
		return tag(atRow: outline.row(at: point)) != nil
	}

	/// Offers to hide or show a right-clicked tag, and nothing for any other row.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let row = outline.clickedRow
		guard let tag = tag(atRow: row) else {
			return
		}
		let isHidden = (outline.item(atRow: row) as? SidebarNode)?.isHidden == true
		let item = NSMenuItem(
			title: isHidden
				? String(localized: "Show Tasks Tagged “\(tag)”")
				: String(localized: "Hide Tasks Tagged “\(tag)”"),
			action: #selector(hiddenTagMenuItemChosen(_:)),
			keyEquivalent: "",
		)
		item.representedObject = tag
		item.target = self
		menu.addItem(item)
	}

	func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		children(of: item)[index]
	}

	func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
		(item as? SidebarNode)?.item == nil
	}

	func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
		!children(of: item).isEmpty
	}

	func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		children(of: item).count
	}

	/// Leaves out the section headers and hidden tags, and leaves the selection as it was where
	/// that's all a click proposed. Unlike `shouldSelectItem`, this gates Select All too.
	func outlineView(
		_: NSOutlineView,
		selectionIndexesForProposedSelection proposed: IndexSet,
	) -> IndexSet {
		let selectable = proposed.filteredIndexSet { row in
			(outline.item(atRow: row) as? SidebarNode)?.isSelectable == true
		}
		return selectable.isEmpty && !proposed.isEmpty ? outline.selectedRowIndexes : selectable
	}

	/// Dims a hidden tag's symbol.
	func outlineView(_: NSOutlineView, tintConfigurationForItem item: Any) -> NSTintConfiguration? {
		(item as? SidebarNode)?.isHidden == true ? .monochrome : nil
	}

	func outlineView(
		_: NSOutlineView,
		typeSelectStringFor _: NSTableColumn?,
		item: Any,
	) -> String? {
		guard let node = item as? SidebarNode, node.isSelectable else {
			return nil
		}
		return node.title
	}

	func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? SidebarNode else {
			return nil
		}
		guard let item = node.item else {
			let cell = outline.reusedCell(HeaderCell.init)
			cell.textField?.stringValue = node.title
			return cell
		}
		let cell = outline.reusedCell(ItemCell.init)
		cell.configure(item, count: node.count, isHidden: node.isHidden)
		return cell
	}

	func outlineViewItemDidCollapse(_ notification: Notification) {
		guard case let .project(name)? = expandedNode(in: notification)?.item else {
			return
		}
		expandedProjects.remove(name)
	}

	func outlineViewItemDidExpand(_ notification: Notification) {
		guard case let .project(name)? = expandedNode(in: notification)?.item else {
			return
		}
		expandedProjects.insert(name)
	}

	func outlineViewSelectionDidChange(_: Notification) {
		guard !isFollowingStore else {
			return
		}
		let selection = Set(outline.selectedRowIndexes.compactMap {
			(outline.item(atRow: $0) as? SidebarNode)?.item
		})
		store.send(.binding(.set(\.sidebarSelection, selection)))
	}

	@objc
	func tagOptionClicked(_ recognizer: NSClickGestureRecognizer) {
		guard let tag = tag(atRow: outline.row(at: recognizer.location(in: outline))) else {
			return
		}
		store.send(.hiddenTagToggled(tag))
	}

	private func children(of item: Any?) -> [SidebarNode] {
		guard let node = item as? SidebarNode else {
			return nodes
		}
		return node.children
	}

	/// The node a expand or collapse notification is about.
	private func expandedNode(in notification: Notification) -> SidebarNode? {
		notification.userInfo?[outlineItemKey] as? SidebarNode
	}

	/// The tag `row` lists, or nil for any other row, or none.
	private func tag(atRow row: Int) -> String? {
		guard case let .tag(tag)? = (outline.item(atRow: row) as? SidebarNode)?.item else {
			return nil
		}
		return tag
	}

	/// Shows the store's sidebar and its selection, reloading only when the sidebar changed, and
	/// keeping expanded the projects that were, and those above a selected one.
	private func updateOutline() {
		let sidebar = store.sidebar
		let selection = store.sidebarSelection
		isFollowingStore = true
		defer {
			isFollowingStore = false
		}
		if sidebar != self.sidebar {
			self.sidebar = sidebar
			nodes = SidebarNode.sections(of: sidebar)
			outline.reloadData()
		}
		for case let .project(name) in selection {
			expandedProjects.formUnion(name.ancestry.dropLast())
		}
		var rows = IndexSet()
		// Top down, so a node's parent is expanded, and the node has a row, by the time it's reached.
		func follow(_ nodes: [SidebarNode]) {
			for node in nodes {
				if let item = node.item, selection.contains(item) {
					let row = outline.row(forItem: node)
					if row >= 0 {
						rows.insert(row)
					}
				}
				if case let .project(name)? = node.item, !expandedProjects.contains(name) {
					continue
				}
				outline.expandItem(node)
				follow(node.children)
			}
		}
		follow(nodes)
		if outline.selectedRowIndexes != rows {
			outline.selectRowIndexes(rows, byExtendingSelection: false)
		}
	}
}

/// A row of the outline: a section header where `item` is nil. A class, since the outline tells
/// its rows apart by identity.
private final class SidebarNode {
	let children: [SidebarNode]
	/// 0 for a section header, which shows none.
	let count: Int
	/// A hidden tag, which can't be selected.
	let isHidden: Bool
	let item: SidebarItem?
	let title: String

	/// Neither a section header nor a hidden tag.
	var isSelectable: Bool {
		item != nil && !isHidden
	}

	/// A section header.
	init(title: String, children: [SidebarNode]) {
		self.children = children
		count = 0
		isHidden = false
		item = nil
		self.title = title
	}

	init(_ item: SidebarItem, count: Int, children: [SidebarNode] = [], isHidden: Bool = false) {
		self.children = children
		self.count = count
		self.isHidden = isHidden
		self.item = item
		title = item.title
	}

	/// The fixed views, then a Projects and a Tags section where either has any.
	static func sections(of sidebar: Sidebar) -> [SidebarNode] {
		var sections = sidebar.views.map { SidebarNode($0.item, count: $0.count) }
		if !sidebar.projects.isEmpty {
			sections.append(
				SidebarNode(title: String(localized: "Projects"), children: sidebar.projects.map(project)),
			)
		}
		if !sidebar.tags.isEmpty {
			sections.append(
				SidebarNode(
					title: String(localized: "Tags"),
					children: sidebar.tags.map {
						SidebarNode($0.item, count: $0.count, isHidden: $0.isHidden)
					},
				),
			)
		}
		return sections
	}

	private static func project(_ project: Sidebar.Project) -> SidebarNode {
		SidebarNode(
			.project(project.name),
			count: project.count,
			children: project.children.map(Self.project),
		)
	}
}

extension SidebarItem {
	fileprivate var symbolName: String {
		switch self {
		case .project: "folder"
		case .tag: "tag"
		case .view(.completed): "checkmark.circle"
		case .view(.deleted): "trash"
		case .view(.pending): "tray"
		case .view(.waiting): "hourglass"
		}
	}

	/// A project by its last segment, since the tree shows the rest.
	fileprivate var title: String {
		switch self {
		case let .project(name): name.components(separatedBy: ".").last ?? name
		case let .tag(tag): tag
		case .view(.completed): String(localized: "Completed")
		case .view(.deleted): String(localized: "Deleted")
		case .view(.pending): String(localized: "Pending")
		case .view(.waiting): String(localized: "Waiting")
		}
	}
}

/// A section's title.
private final class HeaderCell: NSTableCellView {
	init() {
		super.init(frame: .zero)
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
		])
		textField = label
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

/// A symbol and a title, which AppKit sizes and places for the sidebar icon size, and a count.
private final class ItemCell: NSTableCellView {
	private let countLabel = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		let symbol = NSImageView()
		let title = truncatingLabel()
		countLabel.translatesAutoresizingMaskIntoConstraints = false
		for subview in [symbol, title, countLabel] {
			addSubview(subview)
		}
		NSLayoutConstraint.activate([
			countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
			countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
		imageView = symbol
		textField = title
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Ends the title, which AppKit lays out to the trailing edge, short of the count, and sets the
	/// count in the title's size.
	override func layout() {
		super.layout()
		guard let textField, let font = textField.font else {
			return
		}
		if countLabel.font?.pointSize != font.pointSize {
			countLabel.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
		}
		textField.frame.size.width = max(
			0,
			countLabel.frame.minX - countSpacing - textField.frame.minX,
		)
	}

	/// A hidden tag reads struck through and dimmed, with a slashed symbol.
	func configure(_ item: SidebarItem, count: Int, isHidden: Bool) {
		countLabel.stringValue = String(count)
		// A fixed view's count reads brighter than a project's or tag's.
		if case .view = item {
			countLabel.textColor = .secondaryLabelColor
		} else {
			countLabel.textColor = .tertiaryLabelColor
		}
		imageView?.image = NSImage(
			systemSymbolName: isHidden ? "tag.slash" : item.symbolName,
			// VoiceOver's only cue, since the strikethrough is visual alone.
			accessibilityDescription: isHidden ? String(localized: "Hidden") : nil,
		)
		guard let textField else {
			return
		}
		textField.stringValue = item.title
		guard isHidden else {
			return
		}
		// Over the label's own attributes, which carry its font and truncation.
		let title = NSMutableAttributedString(attributedString: textField.attributedStringValue)
		title.addAttributes(
			[
				.foregroundColor: NSColor.secondaryLabelColor,
				.strikethroughStyle: NSUnderlineStyle.single.rawValue,
			],
			range: NSRange(location: 0, length: title.length),
		)
		textField.attributedStringValue = title
	}
}

/// What the Context's popover says: which of its parts apply, and the write defaults skipped.
private func contextSummary(skipped: [String]) -> String {
	let applies = String(
		localized: "The Context’s rc.* overrides and write defaults apply. Its read filter doesn’t: the sidebar and search narrow the list instead.",
	)
	guard !skipped.isEmpty else {
		return applies
	}
	let list = ListFormatter.localizedString(byJoining: skipped)
	return applies + " " + String(localized: "New tasks skip these write defaults: \(list).")
}

private let contextPopoverWidth: CGFloat = 260

/// Between an item's title and its count.
private let countSpacing: CGFloat = 8

/// Where an outline's expand and collapse notifications carry the item, as `NSOutlineView`
/// documents.
private let outlineItemKey = "NSObject"
