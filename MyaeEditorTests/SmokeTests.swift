//
//  SmokeTests.swift
//  MyaeEditorTests
//
//  The editor's own tests moved into the MyaeEditorKit package
//  (run with `swift test`). This placeholder keeps the app's test target
//  non-empty; the real coverage lives in MyaeEditorKitTests.
//

import Testing

struct SmokeTests {
    @Test func appTargetBuilds() {
        #expect(Bool(true))
    }
}
