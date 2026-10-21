import Foundation
import Testing

import PWCore

/// Smoke tests for `LiveProcessNaming` (spec §4-E, v1.1): the single-pid
/// resolver behind `LogLineParser`'s default `resolveClient`.
///
/// Only the shape is asserted, never a machine-specific pid: this runner's own
/// executable must resolve (path + basename), and pids that cannot exist must
/// answer `nil`. The `launchd` case proves the resolver reaches the kernel's
/// own name for a platform process.
@Suite struct ProcessNamingTests {

    @Test func testResolvesItsOwnProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let resolved = try #require(LiveProcessNaming.resolve(pid))

        #expect(!resolved.name.isEmpty)
        let path = try #require(resolved.path)
        #expect(resolved.name == (path as NSString).lastPathComponent)
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test func testResolvesLaunchdThroughTheKernelTable() throws {
        // pid 1 is root-owned and a platform binary, so this exercises the
        // resolver's read of the kernel's process table, not the test's own
        // process.
        let resolved = try #require(LiveProcessNaming.resolve(1))
        #expect(resolved.name == "launchd")
    }

    @Test func testUnresolvablePidsAnswerNil() {
        #expect(LiveProcessNaming.resolve(0) == nil)
        #expect(LiveProcessNaming.resolve(-1) == nil)
        #expect(LiveProcessNaming.resolve(Int32.max) == nil)
    }
}
