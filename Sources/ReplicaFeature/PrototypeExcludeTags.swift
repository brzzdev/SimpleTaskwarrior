// PROTOTYPE, throwaway: three ways to exclude a tag's tasks from the sidebar, switched from the
// Prototype menu. Lives on `prototype/exclude-tags` only.
public import AppKit

public enum PrototypeExcludeVariant: String, CaseIterable, Sendable {
	case altClick = "A"
	case eyeToggle = "C"
	case hiddenSection = "B"

	public static let ordered: [Self] = [.altClick, .hiddenSection, .eyeToggle]

	static let changed = Notification.Name("PrototypeExcludeVariantChanged")

	private static let key = "prototypeExcludeVariant"

	static var current: Self {
		UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .altClick
	}

	public var title: String {
		switch self {
		case .altClick: "A: ⌥-click a tag"
		case .eyeToggle: "C: Eye toggle on hover"
		case .hiddenSection: "B: Right-click → Hidden section"
		}
	}

	@MainActor
	static func select(_ variant: Self) {
		UserDefaults.standard.set(variant.rawValue, forKey: key)
		NotificationCenter.default.post(name: changed, object: nil)
	}
}

/// The Prototype menu's target.
@MainActor
public final class PrototypeExcludeMenu: NSObject, NSMenuItemValidation {
	public static let shared = PrototypeExcludeMenu()

	public func menu() -> NSMenu {
		let menu = NSMenu(title: "Prototype")
		for (index, variant) in PrototypeExcludeVariant.ordered.enumerated() {
			let item = NSMenuItem(
				title: variant.title,
				action: #selector(variantChosen(_:)),
				keyEquivalent: String(index + 1),
			)
			item.keyEquivalentModifierMask = [.command, .control]
			item.representedObject = variant.rawValue
			item.target = self
			menu.addItem(item)
		}
		return menu
	}

	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		item.state = item.representedObject as? String == PrototypeExcludeVariant.current.rawValue
			? .on
			: .off
		return true
	}

	@objc
	func variantChosen(_ sender: NSMenuItem) {
		guard
			let raw = sender.representedObject as? String,
			let variant = PrototypeExcludeVariant(rawValue: raw)
		else {
			return
		}
		PrototypeExcludeVariant.select(variant)
	}
}

/// Hands ⌥-clicks to the sidebar rather than selecting.
final class PrototypeOutlineView: NSOutlineView {
	var altClicked: ((Int) -> Bool)?

	override func mouseDown(with event: NSEvent) {
		let row = row(at: convert(event.locationInWindow, from: nil))
		if event.modifierFlags.contains(.option), row >= 0, altClicked?(row) == true {
			return
		}
		super.mouseDown(with: event)
	}
}
