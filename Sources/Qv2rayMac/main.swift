import AppKit

let arguments = CommandLine.arguments

// `--selftest` runs pure-logic smoke tests and exits (no GUI).
if arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

// `--dump-icons <prefix>` renders the tray icon (both states) as PNGs for visual inspection.
if let idx = arguments.firstIndex(of: "--dump-icons"), arguments.count > idx + 1 {
    let prefix = arguments[idx + 1]
    for (connected, suffix) in [(false, "idle"), (true, "connected")] {
        let img = TrayIcon.image(connected: connected)
        let scaled = NSImage(size: NSSize(width: 128, height: 128), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            img.draw(in: rect)
            return true
        }
        if let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(suffix).png"))
            print("wrote \(prefix)-\(suffix).png")
        }
    }
    exit(0)
}

// `--dump-appicon <path> <size>` renders the app icon (rounded-square + rocket) as PNG.
if let idx = arguments.firstIndex(of: "--dump-appicon"), arguments.count > idx + 2 {
    let path = arguments[idx + 1]
    let size = Int(arguments[idx + 2]) ?? 512
    let img = AppIconGenerator.icon(size: size)
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
    exit(0)
}

// `--snapshot <dir>` launches with demo data in a throwaway data folder, captures every
// screen (light + dark) as PNGs into <dir>, then quits. Never touches real user data.
if let idx = arguments.firstIndex(of: "--snapshot"), arguments.count > idx + 1 {
    SnapshotRunner.prepare(outputDir: arguments[idx + 1])
}

Qv2rayApp.main()
