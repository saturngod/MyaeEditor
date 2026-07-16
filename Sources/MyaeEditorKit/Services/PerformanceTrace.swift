//
//  PerformanceTrace.swift
//  MyaeEditorKit
//
//  Lightweight signposts for the editor's expensive paths. Instruments can
//  aggregate these intervals without logging document content or file paths.
//

import os.signpost

enum PerformanceTrace {
    nonisolated private static let log = OSLog(
        subsystem: "app.myanmars.MyaeEditorKit",
        category: .pointsOfInterest
    )

    nonisolated static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try body()
    }

    nonisolated static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    nonisolated static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
