import Foundation
import ReplicaFeature
import Testing

struct ReplicaNameTests {
	@Test(
		arguments: [
			("/Users/paul/.task", ".task"),
			("/Users/paul/Projects/work-tasks", "work-tasks"),
			("/Users/paul/Work/.task", "Work"),
		],
	)
	func namingRule(path: String, expected: String) {
		let home = URL(filePath: "/Users/paul", directoryHint: .isDirectory)
		let directory = URL(filePath: path, directoryHint: .isDirectory)
		#expect(replicaName(of: directory, home: home) == expected)
	}
}
