//
//  InvisibleWindows.swift
//  Reef
//
//  Windows that draw nothing. Some apps keep a fully transparent window the size of a
//  screen for on-screen effects (Claude's overlay is a titled "Claude" dialog with close
//  and minimize buttons), which the switcher would list as a second window that leads
//  nowhere. Neither Accessibility nor the window server's fields tell it apart from a
//  real window, but its picture does: every pixel is clear.
//
//  Taking a picture costs 75-130 ms, so each window is checked once, off the main
//  thread, and left out from then on. An invisible verdict is checked again after a
//  while, in case the window was only transparent while opening.
//

import AppKit

enum InvisibleWindows {
    private struct Verdict {
        let invisible: Bool
        let checked: CFAbsoluteTime
    }

    private static var verdicts: [CGWindowID: Verdict] = [:]
    private static var pending: Set<CGWindowID> = []
    private static let queue = DispatchQueue(label: "Reef.invisible-windows", qos: .utility)
    private static let recheckAfter: CFAbsoluteTime = 30

    static func isInvisible(_ id: CGWindowID) -> Bool {
        verdicts[id]?.invisible == true
    }

    /// Looks at the windows not checked yet (and stale invisible ones) in the background.
    static func check(_ ids: [CGWindowID]) {
        let now = CFAbsoluteTimeGetCurrent()
        let due = ids.filter { id in
            guard id != 0, !pending.contains(id) else { return false }
            guard let verdict = verdicts[id] else { return true }
            return verdict.invisible && now - verdict.checked > recheckAfter
        }
        guard !due.isEmpty else { return }
        pending.formUnion(due)

        queue.async {
            let results = due.map { ($0, drawsNothing($0)) }
            DispatchQueue.main.async {
                let checked = CFAbsoluteTimeGetCurrent()
                for (id, invisible) in results {
                    pending.remove(id)
                    // No picture at all (closed, minimized, another user's) says nothing.
                    guard let invisible else { continue }
                    if invisible, verdicts[id]?.invisible != true {
                        ActivityLog.log("  window [\(id)] draws nothing; left out of the switcher")
                    }
                    verdicts[id] = Verdict(invisible: invisible, checked: checked)
                }
            }
        }
    }

    /// Every titled, normal-layer window on the Mac, so an overlay that is already up when
    /// Reef starts is known before the first key press.
    static func checkAllWindows() {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let ids = info.compactMap { entry -> CGWindowID? in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  entry[kCGWindowOwnerPID as String] as? pid_t != getpid() else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        }
        check(ids)
    }

    /// True when the window's picture is entirely clear, nil when there is no picture.
    private static func drawsNothing(_ id: CGWindowID) -> Bool? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                  [.boundsIgnoreFraming, .nominalResolution]),
              image.width > 0, image.height > 0 else { return nil }
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        for index in 0..<(side * side) where pixels[index * 4 + 3] != 0 {
            return false
        }
        return true
    }
}
