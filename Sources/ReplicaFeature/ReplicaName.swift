import BookmarkClient
public import Foundation

/// The name a Replica goes by in its window title and in Open Recent.
///
/// A hidden directory, such as Taskwarrior's conventional `.task`, is named after the folder
/// holding it, since every such directory has the same name. In the home folder it keeps its own
/// name: the account name says nothing about the Replica.
public func replicaName(of directory: URL, home: URL = .homeDirectory) -> String {
	let fileManager = FileManager.default
	let name = fileManager.displayName(atPath: directory.path(percentEncoded: false))
	guard directory.lastPathComponent.hasPrefix(".") else {
		return name
	}
	let parent = directory.deletingLastPathComponent()
	guard standardizedFolder(parent) != standardizedFolder(home) else {
		return name
	}
	return fileManager.displayName(atPath: parent.path(percentEncoded: false))
}
