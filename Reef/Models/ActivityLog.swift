//
//  ActivityLog.swift
//  Reef
//
//  Debug builds only: a timeline of every switch (key press, window lookup, focus)
//  in ~/Library/Logs/Reef/activity.log, to find where a slow or missed switch stalls.
//  Release builds compile every call to nothing.
//

import Foundation


enum ActivityLog {
    #if REEF_DEBUG
    private static let queue = DispatchQueue(label: "io.github.iamsumanp.reef.activitylog")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Reef/activity.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    /// Fires every second; a late tick means Reef itself was asleep (App Nap) or blocked.
    nonisolated(unsafe) private static var heartbeat: Timer?
    nonisolated(unsafe) private static var lastBeat = CFAbsoluteTimeGetCurrent()
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if REEF_DEBUG
        let line = "\(formatter.string(from: Date()))  \(message())\n"
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
        #endif
    }

    /// Milliseconds since `start` (a CFAbsoluteTime).
    static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    @MainActor
    static func startHeartbeat() {
        #if REEF_DEBUG
        // Start over past 2 MB; only recent switches matter.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        log("Reef started")
        lastBeat = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let gap = now - lastBeat
            lastBeat = now
            if gap > 3 {
                log("heartbeat late by \(Int(gap - 1)) s (Reef was asleep or blocked)")
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        #endif
    }
}
