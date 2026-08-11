import AppKit

// Build-time hook: `MowerBar --render-icons <dir>` writes the .iconset that
// build.sh feeds to iconutil, plus menu-bar-sized previews for eyeballing.
if let index = CommandLine.arguments.firstIndex(of: "--render-icons"),
   CommandLine.arguments.count > index + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    do {
        try MowerIcon.writeIconSet(to: directory)
        for (name, badge) in [("preview-plain", nil), ("preview-alert", NSColor.systemRed)] as [(String, NSColor?)] {
            if let data = MowerIcon.previewPNG(height: 15, scale: 8, badge: badge) {
                try data.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("icon render failed: \(error)\n".utf8))
        exit(1)
    }
}

// `MowerBar --status` prints exactly what the tray menu would show.
//
// It drives the real FleetMonitor rather than re-querying the API itself, so
// the remembered-mower merge and the action gating shown here cannot drift from
// what the menu does. Respects HOME, which makes it runnable against a throwaway
// support directory.
if CommandLine.arguments.contains("--status") {
    var finished = false
    Task { @MainActor in
        let monitor = FleetMonitor(config: Store.loadConfig())
        await monitor.syncOnce()

        if let error = monitor.lastError {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
        for mower in monitor.mowers {
            let actions = mower.availableActions.map(\.title)
                + mower.startableTasks.compactMap { $0.taskName.map { "Start Task ▸ \($0)" } }
            let seen = mower.lastSeen.map { " (last seen \(AppDelegate.relative($0)))" } ?? ""
            print("""
            \(mower.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \
            \(mower.summary.padding(toLength: 26, withPad: " ", startingAt: 0)) \
            \(String(describing: mower.health).padding(toLength: 10, withPad: " ", startingAt: 0)) \
            \(actions.isEmpty ? "—" : actions.joined(separator: ", "))\(seen)
            """)
        }
        finished = true
    }
    // The work above is main-actor bound, so block by spinning the run loop
    // rather than on a semaphore, which would deadlock it.
    while !finished, RunLoop.current.run(mode: .default, before: .distantFuture) {}
    exit(0)
}

// Top-level code is not main-actor isolated in the Swift 5 language mode, but it
// is genuinely running on the main thread here.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    // `delegate` is held unowned by NSApplication; this scope outlives run().
    app.delegate = delegate
    // Menu bar only: no Dock tile, no main menu.
    app.setActivationPolicy(.accessory)
    app.run()
}
