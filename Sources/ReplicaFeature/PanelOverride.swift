#if DEBUG
public import Foundation

/// The file the next open panel chooses without showing, set by the Debug driver, which can't
/// reach a panel's out-of-process UI.
@MainActor
public enum PanelOverride {
	public static var next: URL?

	/// The file to choose instead of showing a panel, consumed so the panel after shows as usual.
	public static func take() -> URL? {
		defer { next = nil }
		return next
	}
}
#endif
