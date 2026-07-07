import AppKit
import Darwin

// Единственный экземпляр (flock).
func acquireSingleInstanceLock() -> Int32 {
    Paths.ensureDirs()
    let fd = open(Paths.lockFile, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return -1 }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        fputs("Flow Local уже запущен.\n", stderr)
        exit(1)
    }
    let pid = "\(getpid())\n"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return fd
}

let _lockFD = acquireSingleInstanceLock()
log("=== Flow Local v2 (Swift) start ===")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // только меню-бар, без Dock
app.run()
