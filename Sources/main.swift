// Puck Bridge — menu-bar app (https://github.com/mattsinitiere/puckbridge): Harness puck <-> Claude Desktop, no OpenHarness.
//
//   • Recent Claude chats on the puck; select one -> Claude opens it.
//   • Claude finishes a reply in the open chat -> puck beeps + card with the reply's opening.
//   • Tap-and-speak on the puck -> on-device transcription -> typed into the chat (and sent).
//   • Small (bottom) button while Claude is writing -> puck asks "stop?" -> Claude's Stop is pressed.
//   • Pick the character the puck animates (built-in, or your own petdex sprite sheet) and the puck's own
//     settings, from the Settings window or from settings tiles on the puck itself.
//   • Auto-connects, survives unplugs and Claude restarts, can start at login.
//
// Puck protocol from the MIT-licensed autonomous-ai/openharness repo (cli/src/cable/*, firmware cable_client.c,
// pet_store.c, cli/src/cable/pets/*).

import Cocoa
import SwiftUI
import ApplicationServices
import Darwin
import Speech
import AVFoundation
import ServiceManagement
import Security
import ImageIO
import UniformTypeIdentifiers

// ============================================================================================
// MARK: Settings + log
// ============================================================================================
// Keys are shared with the Settings window's @AppStorage, so keep the strings in sync.
enum Pref {
    static let d = UserDefaults.standard
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static var openOnSelect: Bool { get { bool("openOnSelect", true) } set { d.set(newValue, forKey: "openOnSelect") } }
    static var bringForward: Bool { get { bool("bringForward", true) } set { d.set(newValue, forKey: "bringForward") } }
    static var voiceSends: Bool { get { bool("voiceSends", true) } set { d.set(newValue, forKey: "voiceSends") } }
    static var takePuck: Bool { get { bool("takePuck", true) } set { d.set(newValue, forKey: "takePuck") } }
    static var showReply: Bool { get { bool("showReply", true) } set { d.set(newValue, forKey: "showReply") } }
    static var puckTiles: Bool { get { bool("puckTiles", true) } set { d.set(newValue, forKey: "puckTiles") } }
    /// A built-in character's engine name ("claude", "codex", "muse", "fo") or "custom".
    static var character: String { get { d.string(forKey: "character") ?? "claude" } set { d.set(newValue, forKey: "character") } }
    static var customName: String? { get { d.string(forKey: "customName") } set { d.set(newValue, forKey: "customName") } }
}

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PuckBridge.log")
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Puck Bridge")
let customSheetURL = supportDir.appendingPathComponent("custom-character")
let logQueue = DispatchQueue(label: "puckbridge.log")
func say(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    print(line, terminator: "")
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

let HARNESSD = "ai.autonomous.harness.harnessd"
func launchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}
func stopOpenHarness() { launchctl(["bootout", "gui/\(getuid())/\(HARNESSD)"]) }
func startOpenHarness() {
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(HARNESSD).plist").path
    launchctl(["bootstrap", "gui/\(getuid())", plist])
}

/// The certificate this app is signed with ("Puck Bridge Signing"), or nil when ad-hoc signed. macOS remembers
/// permissions per signing identity: ad-hoc builds get a new identity every build, so every update re-asks.
func signingIdentity() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let me = code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(me, SecCSFlags(), &staticCode) == errSecSuccess, let sc = staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let d = info as? [String: Any],
          let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else { return nil }
    return (SecCertificateCopySubjectSummary(leaf) as String?) ?? "a certificate"
}

// ============================================================================================
// MARK: Puck framing   A5 48 | ver | type | len16 | payload | crc16   (little-endian)
// ============================================================================================
let FRAME_VER: UInt8 = 1
let T_JSON: UInt8 = 0x01, T_PCM: UInt8 = 0x02, T_PET: UInt8 = 0x05
let MAX_PAYLOAD = 8192

func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in bytes {
        crc ^= UInt16(b) << 8
        for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
    }
    return crc
}

func encodeFrame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var f: [UInt8] = [0xA5, 0x48, FRAME_VER, type, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    f += payload
    let c = crc16(f[2...])
    f += [UInt8(c & 0xFF), UInt8(c >> 8)]
    return f
}

final class Decoder {
    private var buf: [UInt8] = []
    func reset() { buf = [] }
    func feed(_ data: [UInt8]) -> [(UInt8, [UInt8])] {
        buf += data
        var out: [(UInt8, [UInt8])] = []
        while true {
            guard let i = findMagic() else { buf = Array(buf.suffix(1)); return out }
            if i > 0 { buf.removeFirst(i) }
            if buf.count < 6 { return out }
            let ver = buf[2], type = buf[3], len = Int(buf[4]) | (Int(buf[5]) << 8)
            if ver != FRAME_VER || len > MAX_PAYLOAD { buf.removeFirst(1); continue }
            let total = 6 + len + 2
            if buf.count < total { return out }
            let got = UInt16(buf[6 + len]) | (UInt16(buf[7 + len]) << 8)
            if crc16(buf[2..<(6 + len)]) != got { buf.removeFirst(1); continue }
            out.append((type, Array(buf[6..<(6 + len)])))
            buf.removeFirst(total)
        }
    }
    private func findMagic() -> Int? {
        if buf.count < 2 { return nil }
        for i in 0..<(buf.count - 1) where buf[i] == 0xA5 && buf[i + 1] == 0x48 { return i }
        return nil
    }
}

// ============================================================================================
// MARK: Serial port (raw, clocal, exclusive — same as the official daemon)
// ============================================================================================
enum PortError: Error { case busy, failed(String) }

final class Port {
    let fd: Int32
    init(_ path: String) throws {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_EXLOCK)
        if fd < 0 {
            if errno == EBUSY || errno == EWOULDBLOCK || errno == EAGAIN { throw PortError.busy }
            throw PortError.failed(String(cString: strerror(errno)))
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in p[Int(VMIN)] = 1; p[Int(VTIME)] = 0 }
        }
        tcsetattr(fd, TCSANOW, &t)
        self.fd = fd
    }
    /// nil = nothing yet, [] = gone
    func read(timeoutMs: Int32) -> [UInt8]? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, timeoutMs) <= 0 { return nil }
        if (p.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 && (p.revents & Int16(POLLIN)) == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 { return Array(buf[0..<n]) }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
        return []
    }
    func write(_ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n }
            else if errno == EAGAIN || errno == EWOULDBLOCK { usleep(2000) }
            else { return false }
        }
        return true
    }
    deinit { close(fd) }
}

func puckPorts() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
        .filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
}

// ============================================================================================
// MARK: Claude Desktop via Accessibility
// ============================================================================================
let CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func text(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { text(e, kAXRoleAttribute) }
func point(_ e: AXUIElement) -> CGPoint? {
    guard let v = attr(e, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}
func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(e, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

struct Chat { let id: String; let title: String; let element: AXUIElement }

struct ClaudeView {
    var chats: [Chat] = []
    var writing = false
    var messageLabels: Set<String> = []
    var lastReply = ""
    var mainTexts: [String] = []
    var composerText = ""
    var composer: AXUIElement?
    var sendButton: AXUIElement?
    var stopButton: AXUIElement?
}

final class Claude {
    private(set) var app: AXUIElement?
    private(set) var running: NSRunningApplication?

    func attach() -> Bool {
        guard let r = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == CLAUDE_BUNDLE }) else {
            app = nil; running = nil; return false
        }
        if running?.processIdentifier != r.processIdentifier {
            running = r
            let a = AXUIElementCreateApplication(r.processIdentifier)
            AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = a
            say("Claude Desktop found (pid \(r.processIdentifier))")
        }
        return true
    }

    func read() -> ClaudeView {
        var v = ClaudeView()
        guard let app = app else { return v }
        var seen = 0
        var replies: [String] = []
        var texts: [(String, CGFloat)] = []
        var sidebarRight: CGFloat = 0

        func row(_ button: AXUIElement) -> Chat? {
            var id = "", title = ""
            func look(_ e: AXUIElement, _ d: Int) {
                if d > 5 { return }
                for k in children(e) {
                    let r = role(k)
                    if r == "AXImage", id.isEmpty { id = text(k, "AXDOMIdentifier") }
                    if r == "AXStaticText", title.isEmpty { title = text(k, kAXValueAttribute) }
                    look(k, d + 1)
                }
            }
            look(button, 0)
            return (!id.isEmpty && !title.isEmpty) ? Chat(id: id, title: title, element: button) : nil
        }

        func walk(_ e: AXUIElement, _ d: Int, _ inRow: Bool) {
            seen += 1
            if seen > 30000 || d > 90 { return }
            var inside = inRow
            let r0 = role(e)
            if r0 == "AXStaticText", !inRow {
                let t = text(e, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 1, let p = point(e) { texts.append((t, p.x)) }
            }
            if r0 == "AXTextArea", text(e, kAXDescriptionAttribute).lowercased().contains("prompt") {
                v.composer = e
                v.composerText = text(e, kAXValueAttribute)
            }
            if r0 == "AXButton" {
                let label = text(e, kAXDescriptionAttribute)
                if label == "Stop" || label.hasPrefix("Stop ") { v.writing = true; v.stopButton = e }
                if label == "Send" { v.sendButton = e }
                if label.hasPrefix("Show message actions for ") {
                    v.messageLabels.insert(label)
                    if let r = label.range(of: "Claude responded: ") { replies.append(String(label[r.upperBound...])) }
                }
                if !inRow, let c = row(e) {
                    v.chats.append(c); inside = true
                    if let p = point(e), let s = size(e) { sidebarRight = max(sidebarRight, p.x + s.width) }
                }
            }
            for k in children(e) { walk(k, d + 1, inside) }
        }
        walk(app, 0, false)
        v.lastReply = replies.last ?? ""
        v.mainTexts = texts.filter { $0.1 > sidebarRight + 8 }.map { $0.0 }
        return v
    }

    func open(_ chat: Chat, bringForward: Bool) {
        if bringForward { running?.activate() }
        let r = AXUIElementPerformAction(chat.element, kAXPressAction as CFString)
        if r != .success { say("Couldn't open \"\(chat.title)\" (AX error \(r.rawValue))") }
    }

    func press(_ e: AXUIElement) { _ = AXUIElementPerformAction(e, kAXPressAction as CFString) }
}

// ============================================================================================
// MARK: Voice: on-device speech -> text
// ============================================================================================
struct SimpleError: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

final class Transcriber {
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    static func authorize(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) }
        default: done(false)
        }
    }

    func transcribe(pcm: [UInt8], rate: Double, lang: String, done: @escaping (Result<String, Error>) -> Void) {
        let frames = pcm.count / 2
        guard frames > Int(rate * 0.3) else { done(.failure(SimpleError("Didn't catch that"))); return }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: lang)) ?? SFSpeechRecognizer(), rec.isAvailable else {
            done(.failure(SimpleError("Speech recognition unavailable"))); return
        }
        rec.queue = OperationQueue()
        recognizer = rec
        let req = SFSpeechAudioBufferRecognitionRequest()
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.shouldReportPartialResults = false
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData?[0] else {
            done(.failure(SimpleError("Audio format problem"))); return
        }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let s = Int16(bitPattern: UInt16(pcm[2 * i]) | (UInt16(pcm[2 * i + 1]) << 8))
            ch[i] = Float(s) / 32768
        }
        req.append(buf)
        req.endAudio()
        var finished = false
        let lock = NSLock()
        task = rec.recognitionTask(with: req) { result, error in
            lock.lock(); defer { lock.unlock() }
            if finished { return }
            if let r = result, r.isFinal {
                finished = true; done(.success(r.bestTranscription.formattedString))
            } else if let e = error {
                finished = true; done(.failure(e))
            }
        }
    }
}

// ============================================================================================
// MARK: Characters (the pet the puck animates)
// ============================================================================================
// The puck picks the pet it draws from each chat's `engine` field (firmware focus.c pet_for): a custom pack mapped to
// that engine, else the built-in pet of that name. So a built-in character = the engine we tag chats with, and a
// custom one = an HPET pack uploaded over the cable (frame type 0x05) and mapped to engine "claude".
// Other engines also change the badge colour on the puck (Codex shows its mark); "fo" has no badge.
struct PuckCharacter: Identifiable, Equatable {
    let id: String       // engine name the puck draws this pet for
    let name: String
    let blurb: String
    let symbol: String   // SF Symbol shown in the Settings window
    let aliases: [String]
}
let BUILTIN_CHARACTERS: [PuckCharacter] = [
    PuckCharacter(id: "claude", name: "Clawd", blurb: "Claude's own little guy. The default.", symbol: "sparkles",
                  aliases: ["clawd", "claude", "clod", "cloud", "clawed", "clot", "crab"]),
    PuckCharacter(id: "codex", name: "Codex Bot", blurb: "A small robot. Chat tiles get a Codex badge.", symbol: "cpu",
                  aliases: ["codex", "code x", "codecs", "robot"]),
    PuckCharacter(id: "muse", name: "Jolly", blurb: "Muse's mascot, with headphones. Chat tiles get a Muse badge.", symbol: "headphones",
                  aliases: ["jolly", "muse", "news", "mews", "music"]),
    PuckCharacter(id: "fo", name: "Fo", blurb: "A little pink ghost who runs errands.", symbol: "moon.stars",
                  aliases: ["fo", "foe", "faux", "pho", "ghost", "four"]),
]
let CUSTOM_ID = "custom"

func characterName(_ id: String) -> String {
    if id == CUSTOM_ID { return Pref.customName ?? "Your character" }
    return BUILTIN_CHARACTERS.first { $0.id == id }?.name ?? "Clawd"
}

/// Petdex sprite sheet (8 x 9 cells) -> the puck firmware's HPET pack. A port of OpenHarness
/// cli/src/cable/pets/{sheet,convert,pack}.ts; the firmware parser is pet_store.c (tests/check_pet_pack.c runs it in CI).
enum PetPack {
    static let opaque: UInt8 = 128   // the puck's alpha test: no partial alpha on the dial
    static let IDLE = 0, WAVING = 3, FAILED = 5, WAITING = 6, RUNNING = 7, REVIEW = 8
    static let stepMs = 120, loopSteps = 24, maxColours = 254, maxBytes = 1_048_576

    /// One sheet cell, straight (non-premultiplied) RGBA.
    struct Cell { let w: Int; let h: Int; let px: [UInt8] }
    struct Frame: Hashable { let cols: Int; let rows: Int; let cell: Int; let cells: [UInt8] }
    struct Scene { var frames: [Int]; var stepMs: Int; var dx = 0; var dy = 0 }
    struct Pet {
        var palette: [UInt16]          // RGB565 byte-swapped (panel order); [0] = transparent
        var frames: [Frame]
        var smallW: Int, smallH: Int   // the small pet's 1x size; its frames are drawn at 2x
        var idle: [Int], done: [Int], asking: [Int]
        var working: Scene, listening: Scene, sending: Scene, failed: Scene, relaxing: Scene
        var warnings: [String]
    }
    struct TooBig: LocalizedError {
        let bytes: Int
        var errorDescription: String? {
            String(format: "This character is %.1f MB and the puck holds 1 MB. Try a sheet with fewer frames or colours.", Double(bytes) / 1_048_576)
        }
    }

    // ---------- sheet ----------
    static func cut(width: Int, height: Int, rgba: [UInt8]) throws -> (cellW: Int, cellH: Int, rows: [[Cell]]) {
        guard (width == 1536 && height == 1872) || (width == 768 && height == 936) else {
            throw SimpleError("The sheet must be 1536 × 1872 pixels (8 × 9 frames of 192 × 208), like the ones on petdex.dev. This one is \(width) × \(height).")
        }
        let cw = width / 8, ch = height / 9
        var rows: [[Cell]] = []
        for r in 0..<9 {
            var frames: [Cell] = []
            for c in 0..<8 {
                var px = [UInt8](repeating: 0, count: cw * ch * 4)
                for y in 0..<ch {
                    let from = ((r * ch + y) * width + c * cw) * 4
                    px.replaceSubrange((y * cw * 4)..<((y + 1) * cw * 4), with: rgba[from..<(from + cw * 4)])
                }
                var blank = true
                for i in stride(from: 3, to: px.count, by: 4) where px[i] >= opaque { blank = false; break }
                if blank { break }   // a row ends at its first empty cell
                frames.append(Cell(w: cw, h: ch, px: px))
            }
            rows.append(frames)
        }
        guard rows.contains(where: { !$0.isEmpty }) else { throw SimpleError("The sheet is empty.") }
        return (cw, ch, rows)
    }

    // ---------- colour ----------
    static func rgb565(_ r: Int, _ g: Int, _ b: Int) -> Int { ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3) }
    static func panelOrder(_ v: Int) -> UInt16 { UInt16(((v << 8) | (v >> 8)) & 0xFFFF) }
    static func expand565(_ v: Int) -> (Int, Int, Int) {
        let r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }

    /// Median cut over the distinct RGB565 colours of every opaque pixel, weighted by how often each occurs.
    final class Palette {
        var entries: [Int] = [0]                                   // RGB565, [0] unused (transparent)
        var indexOf = [Int16](repeating: -1, count: 65536)

        init(_ sources: [Cell], _ k: Int) {
            var count = [Double](repeating: 0, count: 65536)
            var sr = count, sg = count, sb = count
            for f in sources {
                for y in stride(from: 0, to: f.h, by: k) {
                    for x in stride(from: 0, to: f.w, by: k) {
                        let i = (y * f.w + x) * 4
                        if f.px[i + 3] < PetPack.opaque { continue }
                        let r = Int(f.px[i]), g = Int(f.px[i + 1]), b = Int(f.px[i + 2])
                        let key = PetPack.rgb565(r, g, b)
                        count[key] += 1; sr[key] += Double(r); sg[key] += Double(g); sb[key] += Double(b)
                    }
                }
            }
            var chan = [[Int]](repeating: [Int](repeating: 0, count: 65536), count: 3)
            for key in 0..<65536 { let e = PetPack.expand565(key); chan[0][key] = e.0; chan[1][key] = e.1; chan[2][key] = e.2 }
            var order = (0..<65536).filter { count[$0] > 0 }
            var boxes: [(lo: Int, hi: Int)] = [(0, order.count)]
            while boxes.count < PetPack.maxColours {
                var pick = -1, pickSpan = 0, pickChannel = 0
                for (bi, b) in boxes.enumerated() where b.hi - b.lo >= 2 {
                    var mn = [255, 255, 255], mx = [0, 0, 0]
                    for i in b.lo..<b.hi {
                        let key = order[i]
                        for c in 0..<3 { let v = chan[c][key]; if v < mn[c] { mn[c] = v }; if v > mx[c] { mx[c] = v } }
                    }
                    var best = 0
                    for c in 1..<3 where mx[c] - mn[c] > mx[best] - mn[best] { best = c }
                    if mx[best] - mn[best] > pickSpan { pick = bi; pickSpan = mx[best] - mn[best]; pickChannel = best }
                }
                if pick < 0 { break }
                let b = boxes[pick]
                let cc = chan[pickChannel]
                order[b.lo..<b.hi].sort { cc[$0] < cc[$1] }
                var total = 0.0
                for i in b.lo..<b.hi { total += count[order[i]] }
                var acc = 0.0, cut = b.lo + 1
                for i in b.lo..<(b.hi - 1) {
                    acc += count[order[i]]
                    cut = i + 1
                    if acc * 2 >= total { break }
                }
                boxes.replaceSubrange(pick...pick, with: [(lo: b.lo, hi: cut), (lo: cut, hi: b.hi)])
            }
            for b in boxes {
                var n = 0.0, r = 0.0, g = 0.0, bl = 0.0
                for i in b.lo..<b.hi { let key = order[i]; n += count[key]; r += sr[key]; g += sg[key]; bl += sb[key] }
                if n == 0 { continue }
                entries.append(PetPack.rgb565(Int((r / n).rounded()), Int((g / n).rounded()), Int((bl / n).rounded())))
                for i in b.lo..<b.hi { indexOf[order[i]] = Int16(entries.count - 1) }
            }
        }

        /// The palette index of a colour; a colour no frame had (a scaled-down mix) takes the nearest entry.
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let key = PetPack.rgb565(r, g, b)
            if indexOf[key] >= 0 { return UInt8(indexOf[key]) }
            var best = 1, bestD = Int.max
            for i in 1..<max(2, entries.count) where i < entries.count {
                let (pr, pg, pb) = PetPack.expand565(entries[i])
                let d = (pr - r) * (pr - r) + (pg - g) * (pg - g) + (pb - b) * (pb - b)
                if d < bestD { bestD = d; best = i }
            }
            indexOf[key] = Int16(best)
            return UInt8(best)
        }
    }

    // ---------- frames ----------
    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// The largest k for which every k x k block of every frame is one colour (pixel art drawn at k x), else 1.
    static func pixelArtFactor(_ frames: [Cell]) -> Int {
        guard let first = frames.first else { return 1 }
        let g = gcd(first.w, first.h)
        var k = g
        while k > 1 {
            if g % k == 0 && frames.allSatisfy({ $0.w == first.w && $0.h == first.h && uniformBlocks($0, k) }) { return k }
            k -= 1
        }
        return 1
    }

    static func uniformBlocks(_ f: Cell, _ k: Int) -> Bool {
        for by in stride(from: 0, to: f.h, by: k) {
            for bx in stride(from: 0, to: f.w, by: k) {
                let o = (by * f.w + bx) * 4
                let solid = f.px[o + 3] >= opaque
                for y in 0..<k {
                    for x in 0..<k {
                        let i = ((by + y) * f.w + bx + x) * 4
                        if (f.px[i + 3] >= opaque) != solid { return false }
                        if solid && (f.px[i] != f.px[o] || f.px[i + 1] != f.px[o + 1] || f.px[i + 2] != f.px[o + 2]) { return false }
                    }
                }
            }
        }
        return true
    }

    /// Opaque edge pixels with partial alpha, over all opaque edge pixels.
    static func softEdgeShare(_ f: Cell) -> Double {
        func solid(_ i: Int) -> Bool { f.px[i + 3] >= opaque }
        var edge = 0, partial = 0
        for y in 0..<f.h {
            for x in 0..<f.w {
                let i = (y * f.w + x) * 4
                if !solid(i) { continue }
                let touches = (x > 0 && !solid(i - 4)) || (x < f.w - 1 && !solid(i + 4)) ||
                              (y > 0 && !solid(i - f.w * 4)) || (y < f.h - 1 && !solid(i + f.w * 4))
                if !touches { continue }
                edge += 1
                if f.px[i + 3] < 255 { partial += 1 }
            }
        }
        return edge == 0 ? 0 : Double(partial) / Double(edge)
    }

    /// A frame at its pixel-art resolution (every k-th pixel), each cell drawn as `cell` px on the puck.
    static func indexFrame(_ f: Cell, _ k: Int, _ cell: Int, _ p: Palette) -> Frame {
        let cols = f.w / k, rows = f.h / k
        var cells = [UInt8](repeating: 0, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                let i = (y * k * f.w + x * k) * 4
                if f.px[i + 3] >= opaque { cells[y * cols + x] = p.nearest(Int(f.px[i]), Int(f.px[i + 1]), Int(f.px[i + 2])) }
            }
        }
        return Frame(cols: cols, rows: rows, cell: cell, cells: cells)
    }

    /// A frame resampled to cols x rows cells of 1 px (the small pet). Nearest sample for even pixel art, else a box
    /// filter; a cell is opaque when at least half of what it covers is.
    static func scaleFrame(_ f: Cell, _ cols: Int, _ rows: Int, _ nearestSample: Bool, _ p: Palette) -> Frame {
        var cells = [UInt8](repeating: 0, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                if nearestSample {
                    let sx = min(f.w - 1, Int((Double(x) + 0.5) * Double(f.w) / Double(cols)))
                    let sy = min(f.h - 1, Int((Double(y) + 0.5) * Double(f.h) / Double(rows)))
                    let i = (sy * f.w + sx) * 4
                    if f.px[i + 3] >= opaque { cells[y * cols + x] = p.nearest(Int(f.px[i]), Int(f.px[i + 1]), Int(f.px[i + 2])) }
                    continue
                }
                let x0 = (x * f.w) / cols
                let x1 = max(x0 + 1, Int((Double((x + 1) * f.w) / Double(cols)).rounded(.up)))
                let y0 = (y * f.h) / rows
                let y1 = max(y0 + 1, Int((Double((y + 1) * f.h) / Double(rows)).rounded(.up)))
                var n = 0, solid = 0, r = 0, g = 0, b = 0
                for sy in y0..<min(y1, f.h) {
                    for sx in x0..<min(x1, f.w) {
                        let i = (sy * f.w + sx) * 4
                        n += 1
                        if f.px[i + 3] < opaque { continue }
                        solid += 1; r += Int(f.px[i]); g += Int(f.px[i + 1]); b += Int(f.px[i + 2])
                    }
                }
                if solid > 0 && solid * 2 >= n {
                    let s = Double(solid)
                    cells[y * cols + x] = p.nearest(Int((Double(r) / s).rounded()), Int((Double(g) / s).rounded()), Int((Double(b) / s).rounded()))
                }
            }
        }
        return Frame(cols: cols, rows: rows, cell: 1, cells: cells)
    }

    // ---------- convert ----------
    /// The petdex reading of the rows: rest = idle, working = running, listening = review, sending = waving,
    /// asking = waiting, relaxing = rest. An empty row falls back to rest.
    static func convert(cellW: Int, cellH: Int, rows: [[Cell]]) throws -> Pet {
        let rest = IDLE
        guard !rows[rest].isEmpty else {
            throw SimpleError("The sheet's first row (idle) is empty, so the puck would have nothing to show.")
        }
        func orRest(_ r: Int) -> Int { rows[r].isEmpty ? rest : r }
        let working = orRest(RUNNING), listening = orRest(REVIEW), sending = orRest(WAVING)
        let asking = orRest(WAITING), failed = orRest(FAILED), relaxing = rest

        var usedKeys: [Int] = [], seenKeys = Set<Int>()
        for r in [working, listening, sending, failed, relaxing, rest, WAVING, asking] {
            for i in rows[r].indices where seenKeys.insert(r * 8 + i).inserted { usedKeys.append(r * 8 + i) }
        }
        let sources = usedKeys.map { rows[$0 / 8][$0 % 8] }
        let k = pixelArtFactor(sources)
        let sceneCell = max(1, Int((Double(k * 192) / Double(cellW)).rounded()))
        let palette = Palette(sources, k)
        var warnings: [String] = []
        if sources.contains(where: { softEdgeShare($0) > 0.02 }) { warnings.append("Soft edges will look a little jagged on the puck.") }

        var frames: [Frame] = []
        var index: [Frame: Int] = [:]
        func add(_ f: Frame) -> Int {
            if let i = index[f] { return i }
            frames.append(f); index[f] = frames.count - 1
            return frames.count - 1
        }
        var full: [Int: Int] = [:]
        func fullIndex(_ key: Int) -> Int {
            if let i = full[key] { return i }
            let i = add(indexFrame(rows[key / 8][key % 8], k, sceneCell, palette))
            full[key] = i
            return i
        }
        func scene(_ r: Int) -> Scene { Scene(frames: rows[r].indices.map { fullIndex(r * 8 + $0) }, stepMs: stepMs) }

        // The small resting pet: the 192 x 208 art fitted into 150 x 112; half of that is its 1x size.
        let fit = min(150.0 / 192.0, 112.0 / 208.0)
        let smallW = Int((192.0 * fit / 2).rounded(.down)), smallH = Int((208.0 * fit / 2).rounded(.down))
        var small: [Int: Int] = [:]
        func smallIndex(_ key: Int) -> Int {
            if let i = small[key] { return i }
            let i = add(scaleFrame(rows[key / 8][key % 8], smallW * 2, smallH * 2, k % 2 == 0, palette))
            small[key] = i
            return i
        }
        let idle = rows[rest].indices.map { smallIndex(rest * 8 + $0) }
        let wave = rows[WAVING].indices.map { smallIndex(WAVING * 8 + $0) }
        var cycles = 3
        while cycles > 1 && idle.count * cycles + wave.count > loopSteps { cycles -= 1 }
        var idleLoop: [Int] = []
        for _ in 0..<cycles { idleLoop += idle }
        idleLoop += wave

        let workingS = scene(working), listeningS = scene(listening), sendingS = scene(sending), failedS = scene(failed)
        let askingLoop = rows[asking].indices.map { smallIndex(asking * 8 + $0) }
        let relaxingS = scene(relaxing)   // last: a version 1 pack leaves out the frames only this scene uses
        return Pet(palette: palette.entries.enumerated().map { $0.offset == 0 ? 0 : panelOrder($0.element) },
                   frames: frames, smallW: smallW, smallH: smallH,
                   idle: Array(idleLoop.prefix(loopSteps)), done: Array(idle.prefix(loopSteps)), asking: Array(askingLoop.prefix(loopSteps)),
                   working: workingS, listening: listeningS, sending: sendingS, failed: failedS, relaxing: relaxingS,
                   warnings: warnings)
    }

    // ---------- pack ----------
    //   "HPET" · version u8 · flags u8 · id u8[8] · length u32 · crc32 u32 (of every byte after the header)
    //   palette: count u8 · count x u16    small: w u16 · h u16 · loops idle/done/asking: n u8 · n x u16
    //   scenes working, listening, sending, failed (+ relaxing in v2): n u8 · step_ms u16 · dx i16 · dy i16 · n x u16
    //   frames: count u16 · per frame: cols u8 · rows u8 · cell u8 · row_at u16[rows] · packed rows
    static func encode(_ pet: Pet, id: [UInt8], version: Int) throws -> [UInt8] {
        do {
            return try encodeExact(pet, id: id, version: version, dropUnused: false)
        } catch is TooBig where version == 2 {
            // Still fits without the relaxing scene? Send that rather than nothing.
            var bare = pet
            bare.relaxing = Scene(frames: [], stepMs: 0)
            return try encodeExact(bare, id: id, version: version, dropUnused: true)
        }
    }

    static func packRows(_ f: Frame) -> (packed: [UInt8], at: [Int]) {
        var packed: [UInt8] = [], at: [Int] = []
        for r in 0..<f.rows {
            at.append(packed.count)
            var x = 0
            while x < f.cols {
                var skip = 0
                while x < f.cols && f.cells[r * f.cols + x] == 0 { skip += 1; x += 1 }
                var run: [UInt8] = []
                while x < f.cols && f.cells[r * f.cols + x] != 0 { run.append(f.cells[r * f.cols + x]); x += 1 }
                packed.append(UInt8(skip)); packed.append(UInt8(run.count)); packed += run
            }
        }
        return (packed, at)
    }

    static func encodeExact(_ pet: Pet, id: [UInt8], version: Int, dropUnused: Bool) throws -> [UInt8] {
        guard id.count == 8, version == 1 || version == 2 else { throw SimpleError("Bad pack id or version") }
        let scenes = version >= 2 ? [pet.working, pet.listening, pet.sending, pet.failed, pet.relaxing]
                                  : [pet.working, pet.listening, pet.sending, pet.failed]
        let refs = pet.idle + pet.done + pet.asking + scenes.flatMap { $0.frames }
        var frames = pet.frames
        if version == 1 || dropUnused { frames = Array(frames.prefix((refs.max() ?? -1) + 1)) }
        guard (refs.max() ?? 0) <= 255 else {
            throw SimpleError("This character has too many different frames for the puck (the most is 256).")
        }
        guard pet.palette.count <= 255, frames.count <= 0xFFFF else { throw SimpleError("This character has too many colours or frames.") }

        var b: [UInt8] = []
        func u8(_ v: Int) { b.append(UInt8(truncatingIfNeeded: v)) }
        func u16(_ v: Int) { b.append(UInt8(truncatingIfNeeded: v)); b.append(UInt8(truncatingIfNeeded: v >> 8)) }
        u8(pet.palette.count)
        for c in pet.palette { u16(Int(c)) }
        u16(pet.smallW); u16(pet.smallH)
        for loop in [pet.idle, pet.done, pet.asking] { u8(loop.count); loop.forEach { u16($0) } }
        for s in scenes { u8(s.frames.count); u16(s.stepMs); u16(s.dx); u16(s.dy); s.frames.forEach { u16($0) } }
        u16(frames.count)
        for f in frames {
            let (packed, at) = packRows(f)
            guard packed.count <= 0xFFFF, f.cols <= 255, f.rows <= 255, f.cols * f.cell <= 480, f.rows * f.cell <= 480 else {
                throw SimpleError("A frame of this character is too large for the puck.")
            }
            u8(f.cols); u8(f.rows); u8(f.cell)
            at.forEach { u16($0) }
            b += packed
        }
        let total = 22 + b.count
        if total > maxBytes { throw TooBig(bytes: total) }
        var head: [UInt8] = Array("HPET".utf8) + [UInt8(version), 0] + id
        let crc = crc32(b)
        for v in [UInt32(total), crc] { for s in stride(from: 0, to: 32, by: 8) { head.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) } }
        return head + b
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    /// CRC-32/IEEE (zlib's crc32).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// An imported sprite sheet, converted and ready to send. Its id is a hash of the file, so the puck keeps a pack it
/// already holds (until it restarts: packs live in RAM).
final class CustomCharacter {
    let id: String
    let idBytes: [UInt8]
    let name: String
    let pet: PetPack.Pet
    let preview: NSImage?
    private var packs: [Int: [UInt8]] = [:]
    private let lock = NSLock()

    private init(id: [UInt8], name: String, pet: PetPack.Pet, preview: NSImage?) {
        idBytes = id
        self.id = id.map { String(format: "%02x", $0) }.joined()
        self.name = name; self.pet = pet; self.preview = preview
    }

    static func make(data: Data, name: String) throws -> CustomCharacter {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SimpleError("That file isn't an image macOS can read. Use a PNG or WebP sprite sheet.")
        }
        let w = img.width, h = img.height
        if !((w == 1536 && h == 1872) || (w == 768 && h == 936)) { _ = try PetPack.cut(width: w, height: h, rgba: []) }
        // Draw into an RGBA buffer in the image's own colour space (no colour shift), then undo premultiplication.
        let space = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw SimpleError("Couldn't read the pixels of that image.") }
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            if a > 0 && a < 255 { for c in 0..<3 { px[i + c] = UInt8(min(255, (Int(px[i + c]) * 255 + a / 2) / a)) } }
        }
        let sheet = try PetPack.cut(width: w, height: h, rgba: px)
        let pet = try PetPack.convert(cellW: sheet.cellW, cellH: sheet.cellH, rows: sheet.rows)
        // FNV-1a 64 of the file: the same sheet always gets the same pack id.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let id = (0..<8).map { UInt8(truncatingIfNeeded: hash >> UInt64(56 - 8 * $0)) }
        let preview = img.cropping(to: CGRect(x: 0, y: 0, width: sheet.cellW, height: sheet.cellH))
            .map { NSImage(cgImage: $0, size: NSSize(width: sheet.cellW, height: sheet.cellH)) }
        let c = CustomCharacter(id: id, name: name, pet: pet, preview: preview)
        _ = try c.pack(2)   // too big? say so now, not when the puck asks
        return c
    }

    func pack(_ version: Int) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        if let p = packs[version] { return p }
        let p = try PetPack.encode(pet, id: idBytes, version: version)
        packs[version] = p
        return p
    }
}

// ============================================================================================
// MARK: Bridge
// ============================================================================================
let MACHINE_ID = "puck-bridge"
let MACHINE_NAME = Host.current().localizedName ?? "Mac"

struct VoiceTurn { var upload: String; var agentId: String?; var rate: Double; var lang: String; var pcm: [UInt8] }

/// What the puck reports in every `hello` and `settings.state`. It stores these itself (NVS), so it is the source of truth.
struct PuckSettings: Equatable {
    var brightness: Int        // 0...100
    var muted: Bool            // true = no finish beep (the puck's factory default)
    var quiet: Bool            // calm mode: the pet doesn't react
    var scrollReversed: Bool
    var voiceLang: String      // ≤ 7 chars, sent back to us as voice.begin's `lang`

    init?(_ d: [String: Any]) {
        guard let b = d["brightness"] as? Int else { return nil }
        brightness = b
        muted = d["muted"] as? Bool ?? true
        quiet = d["quiet"] as? Bool ?? false
        scrollReversed = d["scrollReversed"] as? Bool ?? false
        voiceLang = d["voiceLang"] as? String ?? "en"
    }
    mutating func apply(_ c: [String: Any]) {
        if let v = c["brightness"] as? Int { brightness = max(0, min(100, v)) }
        if let v = c["muted"] as? Bool { muted = v }
        if let v = c["quiet"] as? Bool { quiet = v }
        if let v = c["scrollReversed"] as? Bool { scrollReversed = v }
        if let v = c["voiceLang"] as? String { voiceLang = v }
    }
}

struct ChatItem: Identifiable, Equatable { let id: String; let title: String }

/// Bridge state for the UI, published on the main thread.
struct Snapshot {
    var puck = "Puck: starting…"
    var claude = "Claude: …"
    var puckConnected = false
    var claudeRunning = false
    var axTrusted = true
    var released = false
    var writing = false
    var fw = ""
    var hw = ""
    var chats: [ChatItem] = []
    var puckSettings: PuckSettings?
    var settingsNote = ""
    var petsSupported = false
    var petNote = ""
    var character = Pref.character
}

/// Settings tiles: extra "chats" after the real ones, so the puck's own carousel can change settings.
/// On the default Focus face a touch starts voice for the tile on screen, so: touch, touch again = next value;
/// touch, say a value, touch = that value. (`agent.open` on a tile also counts as a tap.)
enum Tile: String, CaseIterable {
    case character, beep, brightness, calm
    var id: String { "puckbridge-settings-\(rawValue)" }
    init?(id: String?) {
        guard let id = id, let t = Tile.allCases.first(where: { $0.id == id }) else { return nil }
        self = t
    }
    var help: String {
        switch self {
        case .character: return "Tap the face twice for the next character. Or tap, say a name (Clawd, Codex, Jolly, Fo), and tap."
        case .beep: return "Tap the face twice to turn the beep for finished replies on or off."
        case .brightness: return "Tap the face twice for the next level. Or tap, say a number like 60, and tap."
        case .calm: return "Calm mode stops the character reacting to taps and finished replies. Tap the face twice to switch."
        }
    }
}

final class PetTransfer {
    let id: String
    let data: [UInt8]
    var offset = 0, acked = 0
    var accepted = false
    var last = Date()
    init(id: String, data: [UInt8]) { self.id = id; self.data = data }
}

final class Bridge {
    let claude = Claude()
    let transcriber = Transcriber()
    let deliverQueue = DispatchQueue(label: "puckbridge.deliver")
    var port: Port?
    let decoder = Decoder()
    let sendLock = NSLock()
    var greeted = false
    var fw = ""
    var hw = ""
    var view = ClaudeView()
    var pushedKey = ""
    var nextPing = Date()
    var nextConnect = Date()
    var lastClaudeRead = Date.distantPast
    var busyNoticeAt = Date.distantPast
    var axTrusted = AXIsProcessTrusted()
    var released = false   // lent to OpenHarness: don't reopen the port

    // finish detection
    var orderBeforeWriting: [String] = []
    var labelsWhileWriting: Set<String> = []
    var textsBefore: Set<String> = []
    var promptBefore = ""
    var firstSeen: [String: Date] = [:]
    var seenOnce = false
    var writingStarted = Date.distantPast
    var spinnerChat: String?
    var spinnerRefresh = Date.distantFuture
    var emptyReads = 0
    var claudeReadOnce = false

    // selection + voice
    var openedFromPuck: String?
    var lastOpenedId = ""
    var pendingFocus: (id: String, at: Date)?
    var sessionStart = Date()
    var voice: VoiceTurn?

    // puck settings + characters
    var puckSettings: PuckSettings?
    var settingsNote = ""
    var custom: CustomCharacter?
    var petMax = 0
    var petHeld: Set<String> = []
    var petXfer: PetTransfer?
    var petFailed: [String: String] = [:]
    var petMapSent = ""
    var petNote = ""

    var onSnapshot: ((Snapshot) -> Void)?

    // ---------- work from other threads runs here, on the bridge thread ----------
    private var inbox: [(Bridge) -> Void] = []
    private let inboxLock = NSLock()
    func perform(_ f: @escaping (Bridge) -> Void) { inboxLock.lock(); inbox.append(f); inboxLock.unlock() }
    private func drainInbox() {
        inboxLock.lock(); let work = inbox; inbox = []; inboxLock.unlock()
        for f in work { f(self) }
    }

    func publish() {
        var s = Snapshot()
        s.puckConnected = port != nil && greeted
        s.puck = released ? "Puck: lent to OpenHarness"
               : port == nil ? "Puck: not connected" : greeted ? "Puck: connected (fw \(fw))" : "Puck: connecting…"
        s.claudeRunning = claude.app != nil
        s.claude = !axTrusted ? "Claude: needs Accessibility permission"
                 : claude.app == nil ? "Claude: not running" : "Claude: \(view.chats.count) chats\(view.writing ? " · writing…" : "")"
        s.axTrusted = axTrusted
        s.released = released
        s.writing = view.writing
        s.fw = fw; s.hw = hw
        s.chats = view.chats.map { ChatItem(id: $0.id, title: $0.title) }
        s.puckSettings = s.puckConnected ? puckSettings : nil
        s.settingsNote = settingsNote
        s.petsSupported = petMax >= 1
        s.petNote = petNote
        s.character = Pref.character
        DispatchQueue.main.async { self.onSnapshot?(s) }
    }

    // ---------- puck I/O ----------
    func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        sendFrame(T_JSON, [UInt8](data))
    }
    func sendFrame(_ type: UInt8, _ payload: [UInt8]) {
        sendLock.lock(); defer { sendLock.unlock() }
        guard let port = port else { return }
        if !port.write(encodeFrame(type, payload)) { dropPuckLocked("write failed") }
    }
    private func dropPuckLocked(_ why: String) {
        if port != nil { say("Puck disconnected (\(why))") }
        port = nil; greeted = false; pushedKey = ""; voice = nil; decoder.reset()
        petXfer = nil; petMapSent = ""; puckSettings = nil; settingsNote = ""
    }
    func dropPuck(_ why: String) { sendLock.lock(); dropPuckLocked(why); sendLock.unlock(); publish() }

    func connectPuck() {
        for path in puckPorts() {
            do {
                let p = try Port(path)
                sendLock.lock(); port = p; sendLock.unlock()
                say("Opened \(path)"); publish(); return
            } catch PortError.busy {
                if Pref.takePuck {
                    if Date().timeIntervalSince(busyNoticeAt) > 30 { say("\(path) held by OpenHarness — stopping its service"); busyNoticeAt = Date() }
                    stopOpenHarness()
                } else if Date().timeIntervalSince(busyNoticeAt) > 30 {
                    say("\(path) is held by another program (OpenHarness?)"); busyNoticeAt = Date()
                }
            } catch {
                say("Couldn't open \(path): \(error)")
            }
        }
    }

    /// The engine chats are tagged with: it picks the built-in pet (a custom pack is mapped onto "claude").
    var engine: String {
        let c = Pref.character
        return BUILTIN_CHARACTERS.contains(where: { $0.id == c }) ? c : "claude"
    }

    var tiles: [Tile] {
        guard Pref.puckTiles else { return [] }
        return puckSettings == nil ? [.character] : Tile.allCases
    }

    func tileName(_ t: Tile) -> String {
        let s = puckSettings
        switch t {
        case .character: return "Puck character: \(characterName(Pref.character))"
        case .beep: return "Puck beep: " + (s.map { $0.muted ? "Off" : "On" } ?? "?")
        case .brightness: return "Puck brightness: " + (s.map { "\($0.brightness)%" } ?? "?")
        case .calm: return "Puck calm mode: " + (s.map { $0.quiet ? "On" : "Off" } ?? "?")
        }
    }

    func pushChats(force: Bool = false) {
        let eng = engine
        let shown = tiles
        let key = eng + "|" + view.chats.map { "\($0.id)=\($0.title)" }.joined(separator: "|") + "|" + shown.map { tileName($0) }.joined(separator: "|")
        if !force && key == pushedKey { return }
        pushedKey = key
        send(["t": "agents.begin"])
        for c in view.chats {
            send(["t": "agent", "id": c.id, "name": c.title, "engine": eng, "model": "", "effort": "",
                  "machineId": MACHINE_ID, "machine": MACHINE_NAME])
        }
        for t in shown {
            send(["t": "agent", "id": t.id, "name": tileName(t), "engine": eng, "model": "", "effort": "",
                  "machineId": MACHINE_ID, "machine": MACHINE_NAME])
        }
        send(["t": "agents.end", "total": view.chats.count + shown.count, "tab": "claude"])
        // How-to text on each tile; `restore` = history, so no beep and nothing in the drawer.
        for t in shown {
            send(["t": "summary", "agentId": t.id, "name": tileName(t), "engine": eng, "machine": MACHINE_NAME,
                  "recap": t.help, "text": t.help, "restore": true])
        }
        if let s = spinnerChat { send(["t": "turn.started", "agentId": s, "text": "Writing…"]) }
    }

    func toast(_ s: String) { send(["t": "toast", "text": s]) }

    func notify(_ chat: Chat?, _ text: String) {
        let title = chat?.title ?? "Claude"
        let body = !Pref.showReply || text.isEmpty ? "Claude finished replying." : text
        send(["t": "summary", "agentId": chat?.id ?? "claude", "name": title, "engine": engine,
              "machine": MACHINE_NAME, "recap": String(body.prefix(190)), "text": String(body.prefix(1500))])
        say("Finished: \"\(title)\"")
    }

    func handle(_ msg: [String: Any]) {
        let t = msg["t"] as? String ?? ""
        switch t {
        case "hello":
            guard (msg["product"] as? String) == "harness" else { say("Not a Harness puck; ignoring."); dropPuck("foreign"); return }
            send(["t": "welcome", "proto": 3, "app": "Puck Bridge",
                  "machine": ["id": MACHINE_ID, "name": MACHINE_NAME], "selected": MACHINE_ID,
                  "voiceLang": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                  "features": ["agents.refresh", "settings"]])
            fw = msg["fw"] as? String ?? "?"
            hw = msg["hw"] as? String ?? ""
            if let d = msg["settings"] as? [String: Any], let s = PuckSettings(d) { puckSettings = s }
            readPetHello(msg)
            if !greeted {
                greeted = true
                sessionStart = Date()
                say("Puck connected (firmware \(fw)\(petMax >= 1 ? ", custom characters supported" : ""))")
                if claudeReadOnce || !axTrusted { pushChats(force: true) }
                send(["t": "notif.replace", "items": [Any]()])
            } else {
                pushChats()   // only if a tile's value changed
            }
            syncPets()
            publish()
        case "settings.state":
            if let d = msg["settings"] as? [String: Any], let s = PuckSettings(d) { puckSettings = s }
            if (msg["ok"] as? Bool) == false {
                settingsNote = "The puck didn't take that change (\(msg["error"] as? String ?? "no reason given"))."
                say("Puck refused a settings change: \(msg["error"] as? String ?? "?")")
            } else {
                settingsNote = "Saved on the puck."
            }
            if greeted { pushChats() }
            publish()
        case "machines.list":
            send(["t": "machines.begin"])
            send(["t": "machine", "id": MACHINE_ID, "name": MACHINE_NAME, "state": "ready", "local": true])
            send(["t": "machines.end", "selected": MACHINE_ID, "source": "local"])
        case "machine.select":
            send(["t": "machine.selected", "machineId": MACHINE_ID])
        case "agents.list", "agents.refresh":
            pushChats(force: true)
        case "agent.open":
            if let tile = Tile(id: msg["agentId"] as? String) { tileAct(tile, words: nil, turn: nil) }
            else if let id = msg["agentId"] as? String { openChat(id, why: "tap") }
        case "focus":
            if let id = msg["agentId"] as? String, Tile(id: id) == nil { pendingFocus = (id, Date()) }
            else { pendingFocus = nil }
        case "turn.stop":
            let v = claude.read()
            if let stop = v.stopButton { say("Puck → stop Claude"); claude.press(stop) }
            else { toast("Claude isn't writing") }
        case "voice.begin":
            voice = VoiceTurn(upload: msg["uploadId"] as? String ?? "",
                              agentId: msg["agentId"] as? String,
                              rate: (msg["sr"] as? Double) ?? Double(msg["sr"] as? Int ?? 16000),
                              lang: (msg["lang"] as? String) ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                              pcm: [])
        case "voice.abort":
            voice = nil
        case "voice.end":
            if let v = voice {
                voice = nil
                if let tile = Tile(id: v.agentId) { tileVoice(tile, v) } else { finishVoice(v) }
            } else {
                // Always answer, or the puck waits forever (e.g. a reconnect mid-recording lost the audio).
                var m: [String: Any] = ["t": "voice.error", "message": "Didn't catch that"]
                if let u = msg["uploadId"] as? String, !u.isEmpty { m["uploadId"] = u }
                send(m)
            }
        case "pet.accept":
            if let x = petXfer, x.id == msg["id"] as? String { x.accepted = true; x.last = Date(); pumpPet() }
        case "pet.progress":
            if let x = petXfer, x.id == msg["id"] as? String {
                x.acked = msg["written"] as? Int ?? x.acked
                x.last = Date()
                let pct = x.data.isEmpty ? 100 : min(100, x.acked * 100 / x.data.count)
                let note = "Sending \(custom?.name ?? "your character") to the puck… \(pct)%"
                if note != petNote { petNote = note; publish() }
                pumpPet()
            }
        case "pet.done":
            if let id = msg["id"] as? String {
                if petXfer?.id == id { petXfer = nil }
                petHeld.insert(id)
                petNote = "\(custom?.name ?? "Your character") is on the puck."
                say("Custom character stored on the puck (\(id))")
                syncPets(); publish()
            }
        case "pet.error":
            let id = msg["id"] as? String ?? ""
            let reason = msg["reason"] as? String ?? "?"
            if petXfer?.id == id { petXfer = nil }
            petFailed[id] = reason
            switch reason {
            case "busy", "memory": petNote = "The puck is out of room for characters right now. It will try again when the puck reconnects."
            case "version": petNote = "This puck's firmware can't read this kind of character pack."
            default: petNote = "The puck didn't accept this character (\(reason))."
            }
            say("Puck refused the custom character: \(reason)")
            publish()
        default:
            break
        }
    }

    func openChat(_ id: String, why: String) {
        let v = claude.read()
        guard let chat = v.chats.first(where: { $0.id == id }) else { say("Asked to open a chat that's no longer in the sidebar"); return }
        say("Open \"\(chat.title)\" (\(why))")
        openedFromPuck = chat.id
        lastOpenedId = chat.id
        claude.open(chat, bringForward: Pref.bringForward || why == "menu")
    }

    // ---------- puck settings ----------
    func setPuckSettings(_ changes: [String: Any]) {
        guard greeted else { settingsNote = "Connect the puck to change its settings."; publish(); return }
        puckSettings?.apply(changes)   // show it now; settings.state confirms or corrects it
        var m = changes
        m["t"] = "settings.set"
        send(m)
        settingsNote = "Saving…"
        say("Puck settings → \(changes.keys.sorted().joined(separator: ", "))")
        pushChats()
        publish()
    }

    func characterChanged() {
        say("Character: \(characterName(Pref.character))")
        petNote = ""
        syncPets()
        if greeted { pushChats() }
        publish()
    }

    /// The characters the tile cycles through.
    var characterChoices: [String] { BUILTIN_CHARACTERS.map { $0.id } + (custom != nil && petMax >= 1 ? [CUSTOM_ID] : []) }

    /// A tap (words == nil) or a spoken value on a settings tile. `turn` is the voice turn to answer, if any.
    func tileAct(_ tile: Tile, words: String?, turn: VoiceTurn?) {
        func answer(_ text: String, ok: Bool) {
            guard let turn = turn else { return }
            var m: [String: Any] = ok
                ? ["t": "voice.transcript", "routeId": "", "text": text, "agentId": tile.id, "agentName": "Puck settings", "needsConfirm": false]
                : ["t": "voice.error", "message": text]
            if !turn.upload.isEmpty { m["uploadId"] = turn.upload }
            send(m)
        }
        let heard = words?.lowercased() ?? ""
        let tokens = Set(heard.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty })
        /// true / false if the words said on or off (in this tile's terms), nil to just switch.
        func said(on: [String], off: [String]) -> Bool? {
            if !tokens.isDisjoint(with: off) { return false }
            if !tokens.isDisjoint(with: on) { return true }
            return nil
        }
        switch tile {
        case .character:
            let choices = characterChoices
            var next: String?
            if words != nil {
                next = BUILTIN_CHARACTERS.first { c in c.aliases.contains { $0.contains(" ") ? heard.contains($0) : tokens.contains($0) } }?.id
                if next == nil, choices.contains(CUSTOM_ID), !tokens.isDisjoint(with: ["custom", "mine", "own"]) { next = CUSTOM_ID }
                if next == nil, choices.contains(CUSTOM_ID), let n = Pref.customName?.lowercased(), !n.isEmpty, heard.contains(n) { next = CUSTOM_ID }
                if next == nil { answer("Say Clawd, Codex, Jolly or Fo", ok: false); return }
            } else {
                let i = choices.firstIndex(of: Pref.character) ?? -1
                next = choices[(i + 1) % choices.count]
            }
            Pref.character = next!
            characterChanged()
            answer("Character: \(characterName(next!))", ok: true)
        case .beep:
            guard let s = puckSettings else { answer("Waiting for the puck's settings", ok: false); return }
            let on = said(on: ["on", "yes", "loud", "enable"], off: ["off", "no", "mute", "silent", "quiet", "disable"]) ?? s.muted
            setPuckSettings(["muted": !on])
            answer("Beep: \(on ? "On" : "Off")", ok: true)
        case .brightness:
            guard let s = puckSettings else { answer("Waiting for the puck's settings", ok: false); return }
            var level: Int?
            if words == nil {
                level = [20, 40, 60, 80, 100].first { $0 > s.brightness + 2 } ?? 20
            } else if let r = heard.range(of: "[0-9]+", options: .regularExpression) {
                level = Int(heard[r]).map { max(5, min(100, $0)) }
            } else if !tokens.isDisjoint(with: ["max", "maximum", "full", "brightest", "bright", "high"]) {
                level = 100
            } else if !tokens.isDisjoint(with: ["half", "medium", "middle"]) {
                level = 50
            } else if !tokens.isDisjoint(with: ["dim", "low", "dark", "min", "minimum", "dimmest"]) {
                level = 20
            }
            guard let l = level else { answer("Say a number, like 60", ok: false); return }
            setPuckSettings(["brightness": l])
            answer("Brightness: \(l)%", ok: true)
        case .calm:
            guard let s = puckSettings else { answer("Waiting for the puck's settings", ok: false); return }
            let on = said(on: ["on", "yes", "calm", "quiet", "still", "enable"], off: ["off", "no", "lively", "disable"]) ?? !s.quiet
            setPuckSettings(["quiet": on])
            answer("Calm mode: \(on ? "On" : "Off")", ok: true)
        }
        pushChats()
        send(["t": "focus", "agentId": tile.id])   // stay on the tile after the list is re-sent
    }

    /// Voice on a settings tile: a quick touch-touch (under ~1.2 s of audio) is a tap; otherwise listen for a value.
    func tileVoice(_ tile: Tile, _ turn: VoiceTurn) {
        let seconds = Double(turn.pcm.count / 2) / max(turn.rate, 1)
        if seconds < 1.2 { tileAct(tile, words: nil, turn: turn); return }
        Transcriber.authorize { ok in
            guard ok else { self.perform { $0.tileAct(tile, words: nil, turn: turn) }; return }
            self.transcriber.transcribe(pcm: turn.pcm, rate: turn.rate, lang: turn.lang) { result in
                let words = (try? result.get())?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.perform { $0.tileAct(tile, words: words?.isEmpty == false ? words : nil, turn: turn) }
            }
        }
    }

    // ---------- custom characters (HPET packs over the cable) ----------
    private func readPetHello(_ msg: [String: Any]) {
        let was = petHeld
        petMax = msg["pets"] as? Int ?? 0
        let ids = (msg["petIds"] as? [String]) ?? []
        petHeld = Set(petMax >= 1 ? ids : [])
        // The puck restarted under an open link: it forgot the mapping too.
        if !was.isSubset(of: petHeld) { petMapSent = "" }
        if let x = petXfer, petHeld.contains(x.id) { petXfer = nil }   // stored; its pet.done went missing
        petFailed = petFailed.filter { $0.value != "busy" && $0.value != "memory" && $0.value != "stalled" }
    }

    /// Tell the puck which pack draws for "claude" and send it the pack if it doesn't hold it.
    func syncPets() {
        guard greeted, petMax >= 1 else { return }
        let want = Pref.character == CUSTOM_ID ? custom?.id : nil
        let mapKey = want ?? "-"
        if mapKey != petMapSent {
            send(["t": "pet.map", "all": NSNull(), "engines": want.map { ["claude": $0] } ?? [String: String]()])
            petMapSent = mapKey
        }
        for id in petHeld where id != want {   // the puck holds 4 at most; free what nothing uses
            send(["t": "pet.drop", "id": id])
            petHeld.remove(id)
        }
        guard let id = want, let c = custom, petXfer == nil, !petHeld.contains(id), petFailed[id] == nil else { return }
        let pack: [UInt8]
        do { pack = try c.pack(min(petMax, 2)) } catch {
            petFailed[id] = "encode"; petNote = error.localizedDescription; publish(); return
        }
        petXfer = PetTransfer(id: id, data: pack)
        petNote = "Sending \(c.name) to the puck…"
        say("Offering custom character \(id) (\(pack.count) bytes)")
        let crc = Int(pack[18]) | Int(pack[19]) << 8 | Int(pack[20]) << 16 | Int(pack[21]) << 24
        send(["t": "pet.offer", "id": id, "size": pack.count, "crc": crc])
        publish()
    }

    /// Stream pack bytes in ≤ 8 KB frames, never more than 16 KB ahead of the puck's acks: its USB link has no
    /// back-pressure and silently drops what doesn't fit (OpenHarness fwPush.ts).
    private func pumpPet() {
        guard let x = petXfer, x.accepted else { return }
        while x.offset < x.data.count && x.offset - x.acked < 16 * 1024 && port != nil {
            let end = min(x.offset + 8192, x.data.count)
            let slice = Array(x.data[x.offset..<end])
            x.offset = end
            sendFrame(T_PET, slice)
        }
    }

    // ---------- voice ----------
    func finishVoice(_ turn: VoiceTurn) {
        // Called back on Speech's queue: answer the puck from the bridge thread.
        func reply(_ m: [String: Any]) {
            var m = m
            if !turn.upload.isEmpty { m["uploadId"] = turn.upload }
            perform { $0.send(m) }
        }
        let lastOpened = lastOpenedId
        say("Voice: \(turn.pcm.count / 1024) KB of audio, transcribing…")
        Transcriber.authorize { ok in
            guard ok else {
                say("Speech Recognition permission is off (System Settings → Privacy & Security → Speech Recognition)")
                reply(["t": "voice.error", "message": "Allow Speech Recognition for Puck Bridge"]); return
            }
            self.transcriber.transcribe(pcm: turn.pcm, rate: turn.rate, lang: turn.lang) { result in
                switch result {
                case .failure(let e):
                    say("Voice: \(e.localizedDescription)")
                    reply(["t": "voice.error", "message": "Didn't catch that"])
                case .success(let words):
                    let textOut = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    if textOut.isEmpty { reply(["t": "voice.error", "message": "Didn't catch that"]); return }
                    say("Voice: heard \(textOut.split(separator: " ").count) words")
                    self.deliverQueue.async {
                        let target = self.deliver(textOut, to: turn.agentId, lastOpened: lastOpened)
                        reply(["t": "voice.transcript", "routeId": "", "text": textOut,
                               "agentId": target?.id ?? (turn.agentId ?? "claude"),
                               "agentName": target?.title ?? "Claude", "needsConfirm": false])
                    }
                }
            }
        }
    }

    /// Put the words into Claude's message box (in the chat picked on the puck) and, if enabled, send.
    /// Runs on deliverQueue (it sleeps), so bridge state is only changed through perform.
    @discardableResult
    func deliver(_ words: String, to chatId: String?, lastOpened: String) -> Chat? {
        var v = claude.read()
        var target: Chat?
        if let id = chatId, let c = v.chats.first(where: { $0.id == id }) {
            target = c
            if id != lastOpened {
                claude.open(c, bringForward: true)
                perform { $0.lastOpenedId = id; $0.openedFromPuck = id }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        claude.running?.activate()
        // Wait for Claude to really be in front, so ⌘V can't land in another app.
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CLAUDE_BUNDLE {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CLAUDE_BUNDLE else {
            say("Voice: Claude didn't come to the front; not typing"); return target
        }
        v = claude.read()
        guard let box = v.composer else { say("Voice: couldn't find Claude's message box"); return target }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.15)

        // Paste (works with Claude's rich text box), then put the whole clipboard back.
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy
        }
        pb.clearContents(); pb.setString(words, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.5)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }

        if Pref.voiceSends {
            let after = claude.read()
            if let sendBtn = after.sendButton { claude.press(sendBtn); say("Voice: sent") }
            else { say("Voice: pasted, but the Send button wasn't found — press Return to send") }
        } else {
            say("Voice: pasted into Claude (review and send)")
        }
        return target
    }

    // ---------- Claude watching ----------
    func checkClaude() {
        guard claude.attach() else {
            if !view.chats.isEmpty || spinnerChat != nil {
                say("Claude Desktop isn't running")
                if let s = spinnerChat { send(["t": "turn.done", "agentId": s]) }
                spinnerChat = nil; spinnerRefresh = .distantFuture
                view = ClaudeView(); pushChats(); publish()
            }
            return
        }
        let prev = view
        let cur = claude.read()
        let first = !claudeReadOnce
        claudeReadOnce = true

        if cur.chats.isEmpty && !prev.chats.isEmpty {
            emptyReads += 1
            if emptyReads < 3 { return }
        } else { emptyReads = 0 }

        let now = Date()
        for c in cur.chats where firstSeen[c.id] == nil { firstSeen[c.id] = seenOnce ? now : .distantPast }
        seenOnce = true

        if !prev.writing && cur.writing {
            writingStarted = now
            orderBeforeWriting = prev.chats.map { $0.id }
            textsBefore = Set(prev.mainTexts)
            labelsWhileWriting = prev.messageLabels
            promptBefore = prev.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            let guess = openedFromPuck ?? cur.chats.first?.id
            spinnerChat = guess
            spinnerRefresh = now.addingTimeInterval(10)
            if let g = guess { send(["t": "turn.started", "agentId": g, "text": "Writing…"]) }
            say("Claude is writing…")
        }
        if cur.writing { labelsWhileWriting.formUnion(cur.messageLabels) }

        if prev.writing && !cur.writing {
            let kept = textsBefore.intersection(cur.mainTexts).count
            let byText = textsBefore.isEmpty ? !cur.mainTexts.isEmpty
                                             : Double(kept) / Double(textsBefore.count) >= 0.5
            let keptLabels = labelsWhileWriting.intersection(cur.messageLabels).count
            let byLabels = !labelsWhileWriting.isEmpty && Double(keptLabels) / Double(labelsWhileWriting.count) >= 0.5
            let newChat = cur.chats.contains { (firstSeen[$0.id] ?? .distantPast) > writingStarted.addingTimeInterval(-5) }
            let chat = activeChat(in: cur)
            if let s = spinnerChat { send(["t": "turn.done", "agentId": s]) }
            if let c = chat, c.id != spinnerChat { send(["t": "turn.done", "agentId": c.id]) }
            spinnerChat = nil; spinnerRefresh = .distantFuture
            if byText || byLabels || newChat {
                notify(chat, replyText(cur))
            } else {
                say("Switched chats while Claude was writing (no alert)")
            }
        }
        let changed = first || cur.chats.map({ $0.id + $0.title }) != view.chats.map({ $0.id + $0.title }) || cur.writing != view.writing
        view = cur
        if greeted { pushChats() }
        if changed { publish() }
    }

    func replyText(_ v: ClaudeView) -> String {
        let prompt = promptBefore
        let fresh = v.mainTexts.filter { t in
            !textsBefore.contains(t) && !(prompt.count > 3 && (prompt.contains(t) || t.contains(prompt)))
        }
        let joined = fresh.joined(separator: " ")
        return joined.isEmpty ? v.lastReply : joined
    }

    func activeChat(in v: ClaudeView) -> Chat? {
        if let fresh = v.chats.first(where: { (firstSeen[$0.id] ?? .distantPast) > writingStarted.addingTimeInterval(-5) }) { return fresh }
        var best: (Chat, Int)?
        for (i, c) in v.chats.enumerated() {
            if let j = orderBeforeWriting.firstIndex(of: c.id), j - i > (best?.1 ?? 0) { best = (c, j - i) }
        }
        if let b = best { return b.0 }
        if let id = openedFromPuck, let c = v.chats.first(where: { $0.id == id }) { return c }
        return v.chats.first
    }

    // ---------- actions from the menu / Settings window (run via perform) ----------
    func lend() {
        released = true
        dropPuck("lent to OpenHarness")
        startOpenHarness()
        say("Puck lent to OpenHarness; Puck Bridge won't take it back until asked")
        publish()
    }
    func takeBack() { released = false; nextConnect = Date(); say("Taking the puck back"); publish() }
    func reconnect() { dropPuck("reconnect requested"); nextConnect = Date() }
    func testAlert() {
        guard greeted else { say("Test alert: the puck isn't connected"); return }
        let chat = view.chats.first { $0.id == lastOpenedId } ?? view.chats.first
        send(["t": "summary", "agentId": chat?.id ?? "claude", "name": chat?.title ?? "Claude", "engine": engine,
              "machine": MACHINE_NAME, "recap": "Test alert from Puck Bridge. Finished replies look like this.",
              "text": "Test alert from Puck Bridge. Finished replies look like this."])
        say("Sent a test alert to the puck")
    }

    // ---------- main loop (background thread) ----------
    func run() {
        say("Puck Bridge started")
        publish()
        while true {
            drainInbox()
            if port == nil {
                if !released && Date() >= nextConnect {
                    connectPuck()
                    nextConnect = Date().addingTimeInterval(2)
                }
                if port == nil { tickClaude(); usleep(150_000); continue }
            }
            if let data = port?.read(timeoutMs: 100) {
                if data.isEmpty { dropPuck("unplugged") }
                else {
                    for (type, payload) in decoder.feed(data) {
                        if type == T_PCM {
                            if voice != nil && voice!.pcm.count < 4_000_000 { voice!.pcm += payload }
                        } else if type == T_JSON,
                                  let obj = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] {
                            handle(obj)
                        }
                    }
                }
            }
            let now = Date()
            if let f = pendingFocus, now.timeIntervalSince(f.at) > 0.8 {
                pendingFocus = nil
                if Pref.openOnSelect, now.timeIntervalSince(sessionStart) > 3, f.id != lastOpenedId {
                    openChat(f.id, why: "selected on the puck")
                }
            }
            if greeted && now >= nextPing { send(["t": "ping"]); nextPing = now.addingTimeInterval(10) }
            // The puck forgets a tile is busy 25 s after the last turn.started (ui_prune_stale_busy): keep it fresh so
            // the character keeps working and the small button can still stop Claude.
            if greeted, let s = spinnerChat, now >= spinnerRefresh {
                send(["t": "turn.started", "agentId": s, "text": "Writing…"])
                spinnerRefresh = now.addingTimeInterval(10)
            }
            if let x = petXfer, now.timeIntervalSince(x.last) > 10 {
                send(["t": "pet.drop", "id": x.id])
                petXfer = nil; petFailed[x.id] = "stalled"
                petNote = "Sending the character stalled. It will try again when the puck reconnects."
                say("Custom character transfer stalled; dropped")
                publish()
            }
            tickClaude()
        }
    }

    func tickClaude() {
        guard Date().timeIntervalSince(lastClaudeRead) >= 1.0 else { return }
        lastClaudeRead = Date()
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted; publish() }
        if trusted { checkClaude() }
    }
}


// ============================================================================================
// MARK: Updates from GitHub Releases
// ============================================================================================
final class Updater {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "PBUpdateRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private(set) var available: (version: String, url: URL, notes: String)?

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Asks GitHub for the latest release. `done(version, nil)`: an update; `(nil, nil)`: up to date; `(nil, error)`: couldn't check.
    func check(done: @escaping (String?, String?) -> Void) {
        guard repo.contains("/"), let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            say("Updates: no repository configured in this build"); done(nil, "This build has no update repository configured."); return
        }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String) == "PuckBridge.zip" }),
                  let s = zip["browser_download_url"] as? String, let url = URL(string: s) else {
                let why = err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                say("Updates: couldn't check (\(why))")
                done(nil, "Couldn't reach GitHub (\(why)).")
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Updater.newer(version, than: self.current) {
                self.available = (version, url, json["body"] as? String ?? "")
                say("Updates: \(version) available (running \(self.current))")
                done(version, nil)
            } else {
                done(nil, nil)
            }
        }.resume()
    }

    /// Download, unpack, swap the app in place (keeping the old copy until the new one is in), relaunch.
    func install(_ fail: @escaping (String) -> Void) {
        guard let up = available else { return }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { fail("Can't write to \(parent)."); return }
        say("Updates: downloading \(up.version)…")
        URLSession.shared.downloadTask(with: up.url) { tmp, _, err in
            guard let tmp = tmp else { fail(err?.localizedDescription ?? "Download failed"); return }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("puckbridge-\(up.version)")
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", tmp.path, work.path]
            do { try unzip.run(); unzip.waitUntilExit() } catch { fail("Couldn't unpack the update"); return }
            let newApp = work.appendingPathComponent("Puck Bridge.app").path
            guard FileManager.default.fileExists(atPath: newApp) else { fail("The update didn't contain Puck Bridge.app"); return }
            let old = appPath + ".old"
            let script = "sleep 1; rm -rf \"\(old)\"; mv \"\(appPath)\" \"\(old)\" && if mv \"\(newApp)\" \"\(appPath)\"; then rm -rf \"\(old)\"; else mv \"\(old)\" \"\(appPath)\"; fi; xattr -dr com.apple.quarantine \"\(appPath)\" 2>/dev/null; open \"\(appPath)\""
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script]   // keeps running after this app quits
            do { try swap.run() } catch { fail("Couldn't start the installer"); return }
            say("Updates: installing \(up.version) and relaunching")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }
}

// ============================================================================================
// MARK: Settings window (SwiftUI)
// ============================================================================================
enum SettingsTab: Hashable { case general, character, puck, claude, advanced }

/// The UI's view of everything. Lives on the main thread; talks to the bridge only through `bridge.perform`.
final class AppModel: ObservableObject {
    let bridge: Bridge
    let updater: Updater
    @Published var snap = Snapshot()
    @Published var tab: SettingsTab = .general
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var speech = SFSpeechRecognizer.authorizationStatus()
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var custom: CustomCharacter?
    @Published var customBusy = false
    @Published var customNote = ""
    @Published var updateVersion: String?
    @Published var updateNote = ""
    @Published var brightnessDraft: Double?
    @Published var advancedNote = ""
    let signedAs = signingIdentity()
    var onChange: (() -> Void)?

    init(bridge: Bridge, updater: Updater) {
        self.bridge = bridge
        self.updater = updater
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        if let name = Pref.customName, let data = try? Data(contentsOf: customSheetURL) { loadCustom(data: data, name: name, save: false) }
    }

    func update(_ s: Snapshot) {
        snap = s
        if s.axTrusted != axTrusted { axTrusted = s.axTrusted }
        onChange?()
    }

    func refreshPermissions() {
        let ax = AXIsProcessTrusted(), sp = SFSpeechRecognizer.authorizationStatus(), login = SMAppService.mainApp.status
        if ax != axTrusted { axTrusted = ax; onChange?() }
        if sp != speech { speech = sp }
        if login != loginStatus { loginStatus = login }
    }

    var puckDetail: String {
        if snap.released { return "OpenHarness has the puck. Take it back under Advanced." }
        if !snap.puckConnected { return "Plug the puck into this Mac with its USB cable." }
        return snap.hw.isEmpty ? "" : "Hardware \(snap.hw)"
    }

    // ---------- characters ----------
    func choose(_ id: String) {
        Pref.character = id
        snap.character = id
        bridge.perform { $0.characterChanged() }
        onChange?()
    }

    var characterDetail: String {
        if !snap.petsSupported && snap.puckConnected { return "This puck's firmware can't hold custom characters." }
        return snap.character == CUSTOM_ID && !snap.petNote.isEmpty ? snap.petNote : "Your own sprite sheet"
    }

    func importCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a petdex-style sprite sheet (8 × 9 frames, 1536 × 1872 pixels)"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
        loadCustom(data: data, name: String(name.prefix(22)), save: true)
    }

    func loadCustom(data: Data, name: String, save: Bool) {
        customBusy = true
        customNote = save ? "Converting…" : ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let c = try CustomCharacter.make(data: data, name: name)
                if save {
                    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                    try data.write(to: customSheetURL)
                }
                DispatchQueue.main.async {
                    self.customBusy = false
                    self.custom = c
                    Pref.customName = c.name
                    let kb = ((try? c.pack(2).count) ?? 0) / 1024
                    self.customNote = save ? "Ready (\(kb) KB on the puck)." + (c.pet.warnings.isEmpty ? "" : " " + c.pet.warnings.joined(separator: " ")) : ""
                    self.bridge.perform { b in b.custom = c; b.petFailed[c.id] = nil; b.syncPets(); b.pushChats(); b.publish() }
                    if save { self.choose(CUSTOM_ID) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.customBusy = false
                    self.customNote = error.localizedDescription
                    say("Custom character: \(error.localizedDescription)")
                }
            }
        }
    }

    func removeCustom() {
        try? FileManager.default.removeItem(at: customSheetURL)
        Pref.customName = nil
        custom = nil
        customNote = ""
        if snap.character == CUSTOM_ID { choose("claude") }
        bridge.perform { b in b.custom = nil; b.syncPets(); b.pushChats(); b.publish() }
    }

    func refreshPuckList() { bridge.perform { b in if b.greeted { b.pushChats() } } }

    // ---------- puck settings ----------
    func setPuck(_ key: String, _ value: Any) {
        snap.puckSettings?.apply([key: value])
        bridge.perform { $0.setPuckSettings([key: value]) }
        onChange?()
    }
    func commitBrightness() {
        guard let d = brightnessDraft else { return }
        setPuck("brightness", Int(d.rounded()))
        brightnessDraft = nil
    }
    func languages(including current: String) -> [String] {
        var list = ["en", "en-US", "en-GB", "en-AU", "en-IN", "es", "es-MX", "fr", "fr-CA", "de", "it", "pt", "pt-BR",
                    "nl", "sv", "da", "nb", "pl", "tr", "ja", "ko", "zh-CN", "zh-TW", "vi"]
        if !list.contains(current) { list.insert(current, at: 0) }
        return list
    }
    func languageName(_ code: String) -> String {
        (Locale.current.localizedString(forIdentifier: code) ?? code) + "  (\(code))"
    }

    // ---------- app ----------
    func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CLAUDE_BUNDLE) else {
            advancedNote = "Claude Desktop isn't installed."; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func openAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func fixSpeech() {
        if speech == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.refreshPermissions() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        }
    }
    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Couldn't change the login setting",
                  "Add Puck Bridge yourself: System Settings → General → Login Items → +.\n\n\(error.localizedDescription)")
        }
        refreshPermissions()
    }

    func checkUpdates(interactive: Bool) {
        if interactive, updateVersion != nil { confirmInstall(); return }
        if interactive { updateNote = "Checking…" }
        updater.check { version, error in
            DispatchQueue.main.async {
                if let v = version {
                    self.updateVersion = v
                    self.updateNote = "Version \(v) is available."
                    self.onChange?()
                    if interactive { self.confirmInstall() }
                } else if let e = error {
                    self.updateNote = e
                    if interactive { self.alert("Couldn't check for updates", e) }
                } else {
                    self.updateNote = "You're up to date."
                    if interactive { self.alert("You're up to date", "Puck Bridge v\(self.updater.current) is the latest release.") }
                }
            }
        }
    }
    private func confirmInstall() {
        guard let up = updater.available else { return }
        let a = NSAlert()
        a.messageText = "Install Puck Bridge v\(up.version)?"
        a.informativeText = (up.notes.isEmpty ? "" : String(up.notes.prefix(600)) + "\n\n") + "The app will restart. You may need to re-allow Accessibility afterwards."
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Later")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            updateNote = "Downloading…"
            updater.install { msg in DispatchQueue.main.async { self.updateNote = ""; self.alert("Update failed", msg) } }
        }
    }

    func lend() {
        let a = NSAlert()
        a.messageText = "Lend the puck to OpenHarness?"
        a.informativeText = "Puck Bridge lets go of the puck and starts OpenHarness's service, which may update the puck's firmware. Your chats won't show on the puck until you take it back (Settings → Advanced)."
        a.addButton(withTitle: "Lend It"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Pref.takePuck = false
        bridge.perform { $0.lend() }
    }
    func takeBack() {
        Pref.takePuck = true
        bridge.perform { $0.takeBack() }
    }
    func reconnect() { bridge.perform { $0.reconnect() }; advancedNote = "Reconnecting…" }
    func testAlert() {
        bridge.perform { $0.testAlert() }
        advancedNote = snap.puckConnected ? "Sent. The puck should beep (if its beep is on) and show a card." : "The puck isn't connected."
    }
    func copyDiagnostics() {
        let s = snap
        let ps = s.puckSettings.map { "brightness \($0.brightness), beep \($0.muted ? "off" : "on"), calm \($0.quiet), scroll reversed \($0.scrollReversed), voice \($0.voiceLang)" } ?? "not reported"
        let lines = [
            "Puck Bridge v\(updater.current) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(signedAs.map { "signed as \($0)" } ?? "ad-hoc signed")",
            s.puck + (s.hw.isEmpty ? "" : " · hw \(s.hw)"),
            "Puck settings: \(ps)",
            "Character: \(characterName(s.character)) (\(s.character))\(s.petsSupported ? "" : " · custom characters not supported")\(s.petNote.isEmpty ? "" : " · \(s.petNote)")",
            s.claude,
            "Accessibility: \(axTrusted ? "allowed" : "NOT allowed") · Speech: \(speech == .authorized ? "allowed" : "not allowed") · Login item: \(loginStatus == .enabled ? "on" : "off")",
            "Open on select: \(Pref.openOnSelect) · Bring forward: \(Pref.bringForward) · Voice sends: \(Pref.voiceSends) · Take puck: \(Pref.takePuck) · Puck tiles: \(Pref.puckTiles)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        advancedNote = "Copied. Paste it into a message or issue."
    }

    func alert(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body
        NSApp.activate()
        a.runModal()
    }
}

struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            StatusRow(ok: granted, title: title, detail: detail)
            Spacer()
            if granted { Text("Allowed").foregroundStyle(.secondary) } else { Button("Allow…", action: action) }
        }
    }
}

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Status") {
                StatusRow(ok: model.snap.puckConnected, title: model.snap.puck, detail: model.puckDetail)
                HStack {
                    StatusRow(ok: model.snap.claudeRunning && model.axTrusted, title: model.snap.claude,
                              detail: model.snap.writing ? "Claude is writing a reply." : "")
                    Spacer()
                    if !model.snap.claudeRunning { Button("Open Claude") { model.openClaude() } }
                }
            }
            Section("Permissions") {
                PermissionRow(title: "Accessibility", detail: "Lets Puck Bridge see your Claude chats, open them, and type for you.",
                              granted: model.axTrusted, action: model.openAccessibility)
                PermissionRow(title: "Speech Recognition", detail: "Turns what you say into the puck into text, on this Mac.",
                              granted: model.speech == .authorized, action: model.fixSpeech)
                if !model.axTrusted {
                    Text("Already switched on in System Settings? After an update macOS can keep a stale entry. Select Puck Bridge in the list, remove it with −, then add it again with +.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("App") {
                Toggle("Start Puck Bridge when you log in", isOn: Binding(get: { model.loginStatus == .enabled }, set: { model.setLogin($0) }))
                if model.loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS wants you to approve this in Login Items.").font(.caption)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                LabeledContent("Version", value: model.updater.current)
                LabeledContent("Signature", value: model.signedAs.map { "Signed as \($0)" } ?? "Ad-hoc")
                if model.signedAs == nil {
                    Text("macOS asks for permissions again after every update of an ad-hoc build. Setting up signing once stops that (README: Keep macOS permissions across updates).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.updateVersion.map { "Install v\($0)…" } ?? "Check for Updates…") { model.checkUpdates(interactive: true) }
                    Text(model.updateNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CharacterRow: View {
    let symbol: String
    let name: String
    let detail: String
    let image: NSImage?
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Group {
                    if let image = image {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    } else {
                        Image(systemName: symbol).font(.title2)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CharacterPane: View {
    @ObservedObject var model: AppModel
    @AppStorage("puckTiles") private var puckTiles = true
    var body: some View {
        Form {
            Section {
                Text("Choose who lives on your puck. It gets to work while Claude writes, celebrates when a reply is done, and listens when you talk to it.")
                    .foregroundStyle(.secondary)
            }
            Section("Built in") {
                ForEach(BUILTIN_CHARACTERS) { c in
                    CharacterRow(symbol: c.symbol, name: c.name, detail: c.blurb, image: nil,
                                 selected: model.snap.character == c.id) { model.choose(c.id) }
                }
            }
            Section("Your own") {
                if let custom = model.custom {
                    CharacterRow(symbol: "person.crop.circle", name: custom.name, detail: model.characterDetail, image: custom.preview,
                                 selected: model.snap.character == CUSTOM_ID) { model.choose(CUSTOM_ID) }
                    HStack {
                        Button("Replace…") { model.importCustom() }.disabled(model.customBusy)
                        Button("Remove") { model.removeCustom() }.disabled(model.customBusy)
                    }
                } else {
                    Button("Import a Sprite Sheet…") { model.importCustom() }.disabled(model.customBusy)
                }
                if model.customBusy { ProgressView().controlSize(.small) }
                if !model.customNote.isEmpty { Text(model.customNote).font(.caption) }
                Text("Use a petdex-style sheet: 8 × 9 frames, 1536 × 1872 (or 768 × 936) pixels, PNG or WebP. The puck keeps it in memory, so Puck Bridge sends it again after the puck restarts.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Find characters on petdex.dev", destination: URL(string: "https://petdex.dev")!)
            }
            Section("On the puck") {
                Toggle("Show settings tiles on the puck", isOn: $puckTiles)
                    .onChange(of: puckTiles) { _, _ in model.refreshPuckList() }
                Text("Adds tiles after your chats for Character, Beep, Brightness and Calm mode. Stop on one, then tap the face twice to change it. Or tap, say what you want (\"Jolly\", \"60\", \"off\"), and tap again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PuckPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            if let s = model.snap.puckSettings {
                Section("Screen") {
                    Slider(value: Binding(get: { model.brightnessDraft ?? Double(s.brightness) }, set: { model.brightnessDraft = $0 }),
                           in: 5...100, step: 5,
                           label: { Text(verbatim: "Brightness \(Int(model.brightnessDraft ?? Double(s.brightness)))%") },
                           onEditingChanged: { editing in if !editing { model.commitBrightness() } })
                    Toggle("Calm mode (the character doesn't react to taps or finished replies)",
                           isOn: Binding(get: { s.quiet }, set: { model.setPuck("quiet", $0) }))
                    Toggle("Reverse scrolling", isOn: Binding(get: { s.scrollReversed }, set: { model.setPuck("scrollReversed", $0) }))
                }
                Section("Sound") {
                    Toggle("Beep when Claude finishes a reply", isOn: Binding(get: { !s.muted }, set: { model.setPuck("muted", !$0) }))
                }
                Section("Voice") {
                    Picker("Language you speak to the puck", selection: Binding(get: { s.voiceLang }, set: { model.setPuck("voiceLang", $0) })) {
                        ForEach(model.languages(including: s.voiceLang), id: \.self) { code in
                            Text(model.languageName(code)).tag(code)
                        }
                    }
                }
                Section {
                    Text(model.snap.settingsNote.isEmpty ? "These settings are stored on the puck itself." : model.snap.settingsNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(model.snap.puckConnected ? "Waiting for the puck to report its settings…" : "Plug in the puck to change its settings.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("About this puck") {
                LabeledContent("Firmware", value: model.snap.fw.isEmpty ? "—" : model.snap.fw)
                LabeledContent("Hardware", value: model.snap.hw.isEmpty ? "—" : model.snap.hw)
                LabeledContent("Custom characters", value: model.snap.puckConnected ? (model.snap.petsSupported ? "Supported" : "Not supported") : "—")
            }
        }
        .formStyle(.grouped)
    }
}

struct ClaudePane: View {
    @AppStorage("openOnSelect") private var openOnSelect = true
    @AppStorage("bringForward") private var bringForward = true
    @AppStorage("showReply") private var showReply = true
    @AppStorage("voiceSends") private var voiceSends = true
    var body: some View {
        Form {
            Section("Chats") {
                Toggle("Open a chat in Claude when you stop on it on the puck", isOn: $openOnSelect)
                Toggle("Bring Claude to the front when a chat opens", isOn: $bringForward)
            }
            Section("When Claude finishes") {
                Toggle("Show the start of the reply on the puck", isOn: $showReply)
                Text("Turn this off if other people can see your desk. The puck then only says that Claude finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice") {
                Picker("After you speak", selection: $voiceSends) {
                    Text("Type it into Claude and send it").tag(true)
                    Text("Type it into Claude, and I'll press Send").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedPane: View {
    @ObservedObject var model: AppModel
    @AppStorage("takePuck") private var takePuck = true
    var body: some View {
        Form {
            Section("OpenHarness") {
                Toggle("Take the puck from OpenHarness automatically", isOn: $takePuck)
                if model.snap.released {
                    HStack {
                        Text("The puck is lent to OpenHarness.")
                        Spacer()
                        Button("Take It Back") { model.takeBack() }
                    }
                } else {
                    Button("Lend the Puck to OpenHarness…") { model.lend() }
                }
                Text("OpenHarness updates the puck's firmware when it connects. Lending it the puck for a few minutes now and then keeps the firmware current.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Reconnect Puck") { model.reconnect() }
                    Button("Send Test Alert") { model.testAlert() }
                }
                HStack {
                    Button("Open Log") { NSWorkspace.shared.open(logURL) }
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                }
                if !model.advancedNote.isEmpty { Text(model.advancedNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView(selection: $model.tab) {
            GeneralPane(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            CharacterPane(model: model).tabItem { Label("Character", systemImage: "face.smiling") }.tag(SettingsTab.character)
            PuckPane(model: model).tabItem { Label("Puck", systemImage: "circle.circle") }.tag(SettingsTab.puck)
            ClaudePane().tabItem { Label("Claude & Voice", systemImage: "text.bubble") }.tag(SettingsTab.claude)
            AdvancedPane(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }
}

// ============================================================================================
// MARK: Menu-bar app
// ============================================================================================
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let bridge = Bridge()
    let updater = Updater()
    lazy var model = AppModel(bridge: bridge, updater: updater)
    var item: NSStatusItem!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()

        bridge.onSnapshot = { [weak self] s in self?.model.update(s) }
        model.onChange = { [weak self] in self?.updateIcon() }

        // Ask for permissions up front so voice works the first time.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showSettings(.general) }
        }
        Transcriber.authorize { _ in }

        Thread.detachNewThread { [bridge] in bridge.run() }

        // Quietly check for updates shortly after launch, then once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.model.checkUpdates(interactive: false) }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in self.model.checkUpdates(interactive: false) }
    }

    private func updateIcon() {
        let s = model.snap
        let name = !model.axTrusted ? "exclamationmark.circle" : s.puckConnected ? "circle.circle.fill" : "circle.circle"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Puck Bridge")
        item.button?.toolTip = "Puck Bridge\n\(s.puck)\n\(s.claude)" + (model.updateVersion.map { "\nUpdate v\($0) available" } ?? "")
    }

    // The menu is rebuilt every time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = model.snap
        let title = NSMenuItem(title: "Puck Bridge v\(updater.current)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(add(s.puck, #selector(openGeneral)))
        menu.addItem(add(s.claude, s.claudeRunning ? #selector(openGeneral) : #selector(launchClaude)))
        if !model.axTrusted { menu.addItem(add("⚠︎ Allow Accessibility so Puck Bridge can see Claude…", #selector(allowAccessibility))) }
        menu.addItem(.separator())

        if !s.chats.isEmpty {
            let chats = NSMenu()
            for c in s.chats.prefix(25) {
                let i = add(c.title, #selector(openChatItem(_:)))
                i.representedObject = c.id
                chats.addItem(i)
            }
            let parent = NSMenuItem(title: "Open Chat", action: nil, keyEquivalent: "")
            parent.submenu = chats
            menu.addItem(parent)
        }

        let characters = NSMenu()
        var choices = BUILTIN_CHARACTERS.map { ($0.id, $0.name) }
        if let c = model.custom { choices.append((CUSTOM_ID, c.name)) }
        for (id, name) in choices {
            let i = add(name, #selector(chooseCharacter(_:)))
            i.representedObject = id
            i.state = s.character == id ? .on : .off
            characters.addItem(i)
        }
        characters.addItem(.separator())
        characters.addItem(add(model.custom == nil ? "Use Your Own…" : "Change Your Own…", #selector(openCharacter)))
        let charParent = NSMenuItem(title: "Character: \(characterName(s.character))", action: nil, keyEquivalent: "")
        charParent.submenu = characters
        menu.addItem(charParent)

        if let ps = s.puckSettings {
            let beep = add("Beep When Claude Finishes", #selector(toggleBeep))
            beep.state = ps.muted ? .off : .on
            menu.addItem(beep)
        }
        menu.addItem(.separator())
        let settings = add("Settings…", #selector(openGeneral))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(add(model.updateVersion.map { "Install Update v\($0)…" } ?? "Check for Updates…", #selector(checkUpdates)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Puck Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func add(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func showSettings(_ tab: SettingsTab) {
        model.tab = tab
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Puck Bridge"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openGeneral() { showSettings(.general) }
    @objc func openCharacter() { showSettings(.character) }
    @objc func launchClaude() { model.openClaude() }
    @objc func allowAccessibility() { model.openAccessibility(); showSettings(.general) }
    @objc func checkUpdates() { model.checkUpdates(interactive: true) }
    @objc func openChatItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        bridge.perform { $0.openChat(id, why: "menu") }
    }
    @objc func chooseCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.choose(id)
    }
    @objc func toggleBeep() {
        guard let ps = model.snap.puckSettings else { return }
        model.setPuck("muted", !ps.muted)
    }
}

// ============================================================================================
// MARK: Command line (used by CI): PuckBridge --make-pet <sheet.png> <out.hpet> [version]
// ============================================================================================
let argv = CommandLine.arguments
if argv.count >= 4 && argv[1] == "--make-pet" {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: argv[2]))
        let c = try CustomCharacter.make(data: data, name: "test")
        let version = argv.count >= 5 ? Int(argv[4]) ?? 2 : 2
        let pack = try c.pack(version)
        try Data(pack).write(to: URL(fileURLWithPath: argv[3]))
        print("\(argv[3]): \(pack.count) bytes, id \(c.id), \(c.pet.frames.count) frames, \(c.pet.palette.count) colours"
              + (c.pet.warnings.isEmpty ? "" : " (\(c.pet.warnings.joined(separator: " ")))"))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("make-pet: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
