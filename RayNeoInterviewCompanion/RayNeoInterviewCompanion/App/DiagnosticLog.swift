import Foundation
import Observation
import os

/// One timeline for session, audio and Bluetooth events, so effects seen on the glasses can be
/// matched to the exact preceding app action. Also mirrored to the unified log (Console.app /
/// Xcode console, subsystem com.derrancap.RayNeoInterviewCompanion). Contains no audio or transcripts.
@MainActor @Observable final class DiagnosticLog {
    enum Category: String { case session, audio, ble, tx, rx, pipeline }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: Category
        let message: String
        var line: String { "\(DiagnosticLog.stamp(date)) [\(category.rawValue)] \(message)" }
    }

    static let shared = DiagnosticLog()
    private(set) var entries: [Entry] = []
    let capacity: Int
    private let loggers: [Category: Logger]

    init(capacity: Int = 600) {
        self.capacity = capacity
        loggers = Dictionary(uniqueKeysWithValues: [Category.session, .audio, .ble, .tx, .rx, .pipeline].map {
            ($0, Logger(subsystem: "com.derrancap.RayNeoInterviewCompanion", category: $0.rawValue))
        })
    }

    func record(_ category: Category, _ message: String) {
        entries.append(Entry(date: Date(), category: category, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        // Pipeline entries can quote speech; keep them out of the shared system log.
        if category == .pipeline {
            loggers[category]?.notice("\(message, privacy: .private)")
        } else {
            loggers[category]?.notice("\(message, privacy: .public)")
        }
    }

    func clear() { entries.removeAll() }

    var text: String { entries.map(\.line).joined(separator: "\n") }

    nonisolated private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }
}
