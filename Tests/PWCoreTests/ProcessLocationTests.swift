import Foundation
import Testing

import PWCore

/// Tests for `ProcessLocation` (spec §6d `เปิดตำแหน่ง`, plan T21).
///
/// The resolver is pure path logic: every test hands it a literal path (or an
/// injected pid → path function), so nothing here needs a process to really
/// exist — the rule "which part of a path is worth showing in Finder" is
/// pinned literally. The one exception is the smoke test at the end, which asks
/// the real `proc_pidpath` about this test runner's own pid.
@Suite struct ProcessLocationTests {

    /// The app's call shape, with a resolver that knows nothing unless the test
    /// hands it something.
    private func revealURL(
        path: String?,
        pid: Int32? = nil,
        resolver: @escaping (Int32) -> String? = { _ in nil }
    ) -> URL? {
        ProcessLocation.revealURL(for: path, pid: pid, resolver: resolver)
    }

    // MARK: - Bundle extraction

    @Test func testDeepPathInsideABundleResolvesToTheBundle() {
        // The everyday case: an event's `actorPath` is the executable *inside*
        // the bundle — the user wants the app, not the Mach-O.
        let url = revealURL(path: "/Applications/TeamViewer.app/Contents/MacOS/TeamViewer")

        #expect(url?.path == "/Applications/TeamViewer.app")
        #expect(url?.isFileURL == true)
    }

    @Test func testNestedBundlesResolveToTheOutermost() {
        // A helper app inside another app (Chrome's framework layout, Electron
        // updaters, …) is the outer app's business: revealing the inner bundle
        // shows a file inside a package the user did not ask for.
        let url = revealURL(
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Chrome Helper.app/Contents/MacOS/Chrome Helper"
        )

        #expect(url?.path == "/Applications/Google Chrome.app")
    }

    @Test func testTheBundleDirectoryItselfResolvesToItself() {
        #expect(revealURL(path: "/Applications/Foo.app")?.path == "/Applications/Foo.app")
        #expect(revealURL(path: "/Applications/Foo.app/")?.path == "/Applications/Foo.app")
    }

    @Test func testBundleSuffixIsMatchedCaseInsensitively() {
        #expect(revealURL(path: "/Applications/Foo.APP/Contents/MacOS/Foo")?.path == "/Applications/Foo.APP")
    }

    @Test func testAComponentMerelyContainingDotAppIsNotABundle() {
        // `.app` is a suffix, not a substring: `/Users/x/apples/bin/tool` must
        // stay the executable it is.
        #expect(revealURL(path: "/Users/x/apples/bin/tool")?.path == "/Users/x/apples/bin/tool")
    }

    // MARK: - Plain executables

    @Test func testPlainExecutableResolvesToItself() {
        #expect(revealURL(path: "/usr/sbin/screencapture")?.path == "/usr/sbin/screencapture")
        #expect(revealURL(path: "/usr/libexec/screensharingd")?.path == "/usr/libexec/screensharingd")
    }

    // MARK: - Resolver fallback (spec §4-B: a path can be missing)

    @Test func testMissingPathUsesTheResolver() {
        let url = revealURL(path: nil, pid: 4242) { pid in
            pid == 4242 ? "/Applications/RustDesk.app/Contents/MacOS/RustDesk" : nil
        }

        #expect(url?.path == "/Applications/RustDesk.app")
    }

    @Test func testEmptyPathIsTreatedAsMissing() {
        // `<private>` redaction / a truncated line can leave an empty string;
        // it must fall through to the pid lookup, not become the URL "".
        #expect(revealURL(path: "", pid: 7) { _ in "/usr/bin/sleep" }?.path == "/usr/bin/sleep")
    }

    @Test func testAPresentPathNeverConsultsTheResolver() {
        var consulted = false
        let url = revealURL(path: "/usr/sbin/screencapture", pid: 42) { _ in
            consulted = true
            return "/somewhere/else"
        }

        #expect(url?.path == "/usr/sbin/screencapture")
        #expect(consulted == false)
    }

    @Test func testResolverMissIsNil() {
        #expect(revealURL(path: nil, pid: 42) { _ in nil } == nil)
        #expect(revealURL(path: nil, pid: 42) { _ in "" } == nil)
        #expect(revealURL(path: "", pid: nil) { _ in "/usr/bin/sleep" } == nil)
    }

    @Test func testNoPathAndNoPidIsNil() {
        // The caller has nothing to reveal: `nil` is the honest answer, and the
        // menu row simply has no `เปิดตำแหน่ง` action.
        #expect(revealURL(path: nil, pid: nil) { _ in "/usr/bin/sleep" } == nil)
    }

    @Test func testTheResolverIsNotCalledWithoutAPid() {
        var consulted = false
        _ = revealURL(path: nil, pid: nil) { _ in
            consulted = true
            return "/usr/bin/sleep"
        }
        #expect(consulted == false)
    }

    // MARK: - Real resolver (smoke)

    @Test func testSmokeSystemPathResolvesThisRunner() throws {
        // The only test that touches the real machine: the default resolver is
        // `proc_pidpath`, which must name this test runner's own executable (a
        // path that really exists), and the reveal URL must be a file URL.
        let url = try #require(ProcessLocation.revealURL(for: nil, pid: getpid()))

        #expect(url.isFileURL)
        #expect(url.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        print("ProcessLocation smoke — pid \(getpid()) → \(url.path)")
    }
}
