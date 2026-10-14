// Puck Bridge — menu-bar app (https://github.com/mattsinitiere/puckbridge): Harness puck <-> Claude Desktop, no OpenHarness.
//
//   • Recent Claude chats on the puck; select one -> Claude opens it.
//   • Claude finishes a reply in the open chat -> puck beeps + card with the reply's opening.
//   • Tap-and-speak on the puck -> on-device transcription -> typed into the chat (and sent).
//   • Small (bottom) button while Claude is writing -> puck asks "stop?" -> Claude's Stop is pressed.
//   • Pick the character the puck animates (built-in, or your own petdex sprite sheet) and the puck's own
//     settings, from the Settings window or from the Settings tab on the puck itself.
//   • Puck tabs: Chats, Claude Code sessions, one per Code project folder, and Settings.
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
import CoreLocation
import CryptoKit

// ============================================================================================
// MARK: Settings + log
// ============================================================================================
// Keys are shared with the Settings window's @AppStorage, so keep the strings in sync.
enum Pref {
    static let d = UserDefaults.standard
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static var openOnSelect: Bool { get { bool("openOnSelect", true) } set { d.set(newValue, forKey: "openOnSelect") } }
    /// Bring Claude to the front when a chat is opened from the puck (off: Claude opens it in the background).
    static var bringForward: Bool { get { bool("bringForward", false) } set { d.set(newValue, forKey: "bringForward") } }
    static var voiceSends: Bool { get { bool("voiceSends", true) } set { d.set(newValue, forKey: "voiceSends") } }
    static var takePuck: Bool { get { bool("takePuck", true) } set { d.set(newValue, forKey: "takePuck") } }
    static var showReply: Bool { get { bool("showReply", true) } set { d.set(newValue, forKey: "showReply") } }
    static var puckTiles: Bool { get { bool("puckTiles", true) } set { d.set(newValue, forKey: "puckTiles") } }
    static var codeTabs: Bool { get { bool("codeTabs", true) } set { d.set(newValue, forKey: "codeTabs") } }
    /// The puck tab last chosen ("chats", "code-<hash>" for one Claude Code project, or "settings").
    static var tab: String { get { d.string(forKey: "tab") ?? "chats" } set { d.set(newValue, forKey: "tab") } }
    /// A built-in character's engine name ("claude", "codex", "muse", "fo") or "custom".
    static var character: String { get { d.string(forKey: "character") ?? "claude" } set { d.set(newValue, forKey: "character") } }
    static var betaAccess: Bool { get { bool("betaAccess", false) } set { d.set(newValue, forKey: "betaAccess") } }
    static var customName: String? { get { d.string(forKey: "customName") } set { d.set(newValue, forKey: "customName") } }
    // Clock face (Puck Bridge firmware only)
    static var idleMin: Int { get { d.object(forKey: "idleMin") as? Int ?? 5 } set { d.set(newValue, forKey: "idleMin") } }
    static var clock24: Bool {
        get { d.object(forKey: "clock24") as? Bool ?? !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h").contains("a") }
        set { d.set(newValue, forKey: "clock24") }
    }
    static var weatherOn: Bool { get { bool("weatherOn", true) } set { d.set(newValue, forKey: "weatherOn") } }
    /// Finish sound on Puck Bridge firmware (one of SOUND_STYLES) and its volume.
    static var soundStyle: String { get { d.string(forKey: "soundStyle") ?? "chime" } set { d.set(newValue, forKey: "soundStyle") } }
    /// How the puck draws its chat and tab lists (Puck Bridge firmware pb.5): "cards", "dial", "compact" or "classic".
    static var listStyle: String { get { d.string(forKey: "listStyle") ?? "cards" } set { d.set(newValue, forKey: "listStyle") } }
    /// The puck's appearance (Puck Bridge firmware pb.6): "dark", "light" or "auto" (follow the Mac).
    static var puckTheme: String { get { d.string(forKey: "puckTheme") ?? "dark" } set { d.set(newValue, forKey: "puckTheme") } }
    static var soundVolume: Int { get { d.object(forKey: "soundVolume") as? Int ?? 75 } set { d.set(newValue, forKey: "soundVolume") } }
    /// The last timer length started on the puck, in minutes.
    static var timerLast: Int { get { d.object(forKey: "timerLast") as? Int ?? 5 } set { d.set(newValue, forKey: "timerLast") } }
    /// Keep the character library in iCloud Drive too, so every Mac signed in to it has the same characters.
    static var syncCharacters: Bool { get { bool("syncCharacters", true) } set { d.set(newValue, forKey: "syncCharacters") } }
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
let T_JSON: UInt8 = 0x01, T_PCM: UInt8 = 0x02, T_FW: UInt8 = 0x03, T_LOG: UInt8 = 0x04, T_PET: UInt8 = 0x05
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

/// FNV-1a 64, hex: short stable ids from names (tab ids, Code session ids).
func fnv64(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// Which list Claude's sidebar shows: the Mode switch at its top ("Chat and Cowork" / "Code").
enum ClaudeMode: String { case chat, code, unknown }

/// A sidebar row. On Chat mode a chat (id = its status icon's AXDOMIdentifier); on Code mode a Claude Code session,
/// listed under its project (id = CODE_PREFIX + hash of project and title, so it survives Claude re-drawing the list).
/// `element` is nil for rows remembered from the other mode, or from the last run.
struct Chat {
    let id: String
    let title: String
    let element: AXUIElement?
    var project: String? = nil
    var status = ""
    var label = ""   // the row button's title: "<status> <title>"
    var isCode: Bool { project != nil }
}
let CODE_PREFIX = "cc-"
func codeId(project: String, title: String) -> String { CODE_PREFIX + fnv64(project + "\n" + title) }

struct ClaudeView {
    var mode = ClaudeMode.unknown
    var modeButtons: [ClaudeMode: AXUIElement] = [:]
    var openTitle = ""          // the open conversation, from its web area's title ("<title> - Claude Code")
    var chats: [Chat] = []      // the rows the sidebar shows now (chats, or Code sessions)
    /// Code view: every project in sidebar order, folded ones too, with the button that folds/unfolds it.
    var projects: [(name: String, header: AXUIElement?)] = []
    var writing = false
    var messageLabels: Set<String> = []
    var lastReply = ""
    var mainTexts: [String] = []
    var composerText = ""
    var composer: AXUIElement?
    var sendButton: AXUIElement?
    var stopButton: AXUIElement?
    var stopLabel = ""
}

final class Claude {
    private(set) var app: AXUIElement?
    private(set) var running: NSRunningApplication?
    private var lastUnfold: (project: String, at: Date)?

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
        var titleMode = ClaudeMode.unknown

        /// A row button: its status icon (id + description) and its title text.
        func row(_ button: AXUIElement) -> (dom: String, status: String, title: String)? {
            var id = "", status = "", title = ""
            func look(_ e: AXUIElement, _ d: Int) {
                if d > 5 { return }
                for k in children(e) {
                    let r = role(k)
                    if r == "AXImage", id.isEmpty { id = text(k, "AXDOMIdentifier"); status = text(k, kAXDescriptionAttribute) }
                    if r == "AXStaticText", title.isEmpty { title = text(k, kAXValueAttribute) }
                    look(k, d + 1)
                }
            }
            look(button, 0)
            return (!id.isEmpty && !title.isEmpty) ? (id, status, title) : nil
        }

        var rows: [(e: AXUIElement, dom: String, status: String, title: String, label: String, project: String?)] = []
        func walk(_ e: AXUIElement, _ d: Int, _ inRow: Bool, _ project: String?) {
            seen += 1
            if seen > 30000 || d > 90 { return }
            var inside = inRow
            var project = project
            let r0 = role(e)
            let kids = children(e)
            switch r0 {
            case "AXStaticText" where !inRow:
                let t = text(e, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 1, let p = point(e) { texts.append((t, p.x)) }
            case "AXTextArea":
                if text(e, kAXDescriptionAttribute).lowercased().contains("prompt") {
                    v.composer = e
                    v.composerText = text(e, kAXValueAttribute)
                }
            case "AXWebArea":
                let t = text(e, kAXTitleAttribute)
                if let r = t.range(of: " - Claude Code", options: [.anchored, .backwards]) { v.openTitle = String(t[..<r.lowerBound]); titleMode = .code }
                else if let r = t.range(of: " - Claude", options: [.anchored, .backwards]) { v.openTitle = String(t[..<r.lowerBound]); titleMode = .chat }
            case "AXRadioButton":
                // The Mode switch: "Chat and Cowork…" / "Code". The selected one has value 1.
                let label = text(e, kAXDescriptionAttribute)
                let m: ClaudeMode = label.hasPrefix("Code") ? .code : label.hasPrefix("Chat") ? .chat : .unknown
                if m != .unknown {
                    v.modeButtons[m] = e
                    if (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1 { v.mode = m }
                }
            case "AXGroup":
                // A Code project in the sidebar: a group holding "<name>" and "New session in <name>".
                for k in kids where role(k) == "AXButton" {
                    let label = text(k, kAXDescriptionAttribute)
                    if label.hasPrefix("New session in ") {
                        let name = String(label.dropFirst("New session in ".count))
                        project = name
                        if !v.projects.contains(where: { $0.name == name }) {
                            let header = kids.first { role($0) == "AXButton" && text($0, kAXTitleAttribute) == name }
                            v.projects.append((name, header))
                        }
                        break
                    }
                }
            case "AXButton":
                let label = text(e, kAXDescriptionAttribute)
                if label == "Stop" || label.hasPrefix("Stop ") { v.writing = true; v.stopButton = e; v.stopLabel = label }
                if label == "Send" { v.sendButton = e }
                if label.hasPrefix("Show message actions for ") {
                    v.messageLabels.insert(label)
                    if let r = label.range(of: "Claude responded: ") { replies.append(String(label[r.upperBound...])) }
                }
                if !inRow, let c = row(e) {
                    rows.append((e, c.dom, c.status, c.title, text(e, kAXTitleAttribute), project)); inside = true
                    if let p = point(e), let s = size(e) { sidebarRight = max(sidebarRight, p.x + s.width) }
                }
            default:
                break
            }
            for k in kids { walk(k, d + 1, inside, project) }
        }
        walk(app, 0, false, nil)
        if v.mode == .unknown { v.mode = titleMode }
        if v.mode == .unknown && rows.contains(where: { $0.project != nil }) { v.mode = .code }
        var used: [String: Int] = [:]
        v.chats = rows.map { r in
            // On Code mode every row is a session; one outside any project group goes under "Code".
            let project = r.project ?? (v.mode == .code ? "Code" : nil)
            guard let p = project else { return Chat(id: r.dom, title: r.title, element: r.e, status: r.status, label: r.label) }
            // Two sessions with the same title in one project ("New session") get their own ids, in sidebar order.
            var id = codeId(project: p, title: r.title)
            used[id, default: 0] += 1
            if used[id]! > 1 { id += "-\(used[id]!)" }
            return Chat(id: id, title: r.title, element: r.e, project: p, status: r.status, label: r.label)
        }
        v.lastReply = replies.last ?? ""
        v.mainTexts = texts.filter { $0.1 > sidebarRight + 8 }.map { $0.0 }
        return v
    }

    func open(_ chat: Chat, bringForward: Bool) {
        if bringForward { running?.activate() }
        guard let e = chat.element else { say("Couldn't open \"\(chat.title)\": it isn't on screen"); return }
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        if r != .success { say("Couldn't open \"\(chat.title)\" (AX error \(r.rawValue))") }
    }

    /// Switch the sidebar between chats and Code sessions (the Mode switch at its top).
    @discardableResult
    func show(_ mode: ClaudeMode, in v: ClaudeView) -> Bool {
        guard v.mode != mode else { return true }
        guard let b = v.modeButtons[mode] else { say("Couldn't find Claude's \(mode == .code ? "Code" : "Chat") switch"); return false }
        say("Claude → \(mode == .code ? "Code" : "Chat") sessions")
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }

    func press(_ e: AXUIElement) { _ = AXUIElementPerformAction(e, kAXPressAction as CFString) }

    /// Unfold a Code project in the sidebar (press its name) if it shows no sessions. True if pressed.
    /// Pressing the name again folds it, so the same project is never pressed twice within a few seconds.
    @discardableResult
    func unfold(_ project: String, in v: ClaudeView) -> Bool {
        guard v.mode == .code, !v.chats.contains(where: { $0.project == project }),
              let h = v.projects.first(where: { $0.name == project })?.header else { return false }
        if let l = lastUnfold, l.project == project, Date().timeIntervalSince(l.at) < 4 { return false }
        lastUnfold = (project, Date())
        say("Claude → unfold the Code project \"\(project)\"")
        return AXUIElementPerformAction(h, kAXPressAction as CFString) == .success
    }

    /// Claude's window structure for support: roles, button labels and ids, never the conversation text.
    func layoutDump() -> String {
        guard let app = app else { return "Claude Desktop isn't running." }
        var lines: [String] = [], n = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            n += 1
            if n > 6000 || d > 45 { return }
            let r = role(e)
            var desc = text(e, kAXDescriptionAttribute)
            if desc.hasPrefix("Show message actions") { desc = "Show message actions…" }
            let title = r == "AXStaticText" ? "" : text(e, kAXTitleAttribute)
            let dom = text(e, "AXDOMIdentifier")
            let selected = (attr(e, kAXSelectedAttribute) as? Bool) == true
                || (r == "AXRadioButton" && (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1)
            var line = String(repeating: " ", count: d) + r
            if !desc.isEmpty { line += " desc=\"\(desc.prefix(60))\"" }
            if !title.isEmpty { line += " title=\"\(title.prefix(60))\"" }
            if selected { line += " selected" }
            if !dom.isEmpty { line += " id=\(dom)" }
            lines.append(line)
            for k in children(e) { walk(k, d + 1) }
        }
        walk(app, 0)
        return lines.joined(separator: "\n")
    }
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
/// Finish sounds Puck Bridge firmware can play (firmware/README.md).
let SOUND_STYLES: [(id: String, name: String)] = [("chime", "Chime"), ("soft", "Soft"), ("bell", "Bell"), ("digital", "Digital")]
func soundName(_ id: String) -> String { SOUND_STYLES.first { $0.id == id }?.name ?? "Chime" }
/// The puck's list styles (`pb.ui {lists}`, Puck Bridge firmware pb.5); "classic" is the official firmware's green pages.
let LIST_STYLES: [(id: String, name: String)] = [("cards", "Cards"), ("dial", "Dial"), ("compact", "Compact list"), ("classic", "Classic")]
func listStyleName(_ id: String) -> String { LIST_STYLES.first { $0.id == id }?.name ?? "Cards" }
let PUCK_THEMES: [(id: String, name: String)] = [("dark", "Dark"), ("light", "Light"), ("auto", "Match Mac")]
func puckThemeName(_ id: String) -> String { PUCK_THEMES.first { $0.id == id }?.name ?? "Dark" }
/// The theme the puck should show now: "auto" follows the Mac's light/dark appearance.
func puckThemeNow() -> String {
    Pref.puckTheme != "auto" ? Pref.puckTheme : UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
}

let CUSTOM_ID = "custom"   // the old single "your own" slot; migrated into the library
let LIB_PREFIX = "lib:"
let libraryDir = supportDir.appendingPathComponent("Characters")
func isLibrary(_ id: String) -> Bool { id.hasPrefix(LIB_PREFIX) }

func characterName(_ id: String) -> String {
    if let c = CharacterLibrary.shared.find(id) { return c.name }
    return BUILTIN_CHARACTERS.first { $0.id == id }?.name ?? "Clawd"
}

/// An imported character: libraryDir/<slug>/ holds its sprite sheet and character.json {name, sheet}.
struct LibraryCharacter: Identifiable, Equatable { let id: String; let name: String; let sheet: URL; let dir: URL }

/// The characters you've imported. They live on this Mac only (never in the app or the repo); the puck gets the
/// chosen one as a pack over the cable.
final class CharacterLibrary {
    static let shared = CharacterLibrary()
    private let lock = NSLock()
    private var items: [LibraryCharacter] = []

    var all: [LibraryCharacter] { lock.lock(); defer { lock.unlock() }; return items }
    func find(_ id: String) -> LibraryCharacter? { all.first { $0.id == id } }

    func reload() {
        sync()
        var out: [LibraryCharacter] = []
        for dir in (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("character.json")),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let name = j["name"] as? String, let sheet = j["sheet"] as? String else { continue }
            out.append(LibraryCharacter(id: LIB_PREFIX + dir.lastPathComponent, name: name, sheet: dir.appendingPathComponent(sheet), dir: dir))
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.lock(); items = out; lock.unlock()
    }

    /// Names arrive with invisible characters sometimes (petdex's "Pikachu‌" has a zero-width joiner).
    static func clean(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(22).description
    }

    /// Imports sprite sheets, petdex folders (pet.json + spritesheet), and .zip files of either, zips inside zips
    /// included. Each one is converted once to check it fits the puck. Background thread.
    func importItems(_ urls: [URL]) -> (added: [LibraryCharacter], errors: [String]) {
        var found: [(name: String, data: Data, ext: String)] = []
        var errors: [String] = []
        let fm = FileManager.default
        func scan(_ url: URL, _ depth: Int) {
            guard depth < 5, !url.lastPathComponent.hasPrefix("."), url.lastPathComponent != "__MACOSX" else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                if let d = try? Data(contentsOf: url.appendingPathComponent("pet.json")),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let path = j["spritesheetPath"] as? String, let sheet = try? Data(contentsOf: url.appendingPathComponent(path)) {
                    let name = (j["displayName"] as? String) ?? (j["id"] as? String) ?? url.lastPathComponent
                    found.append((CharacterLibrary.clean(name), sheet, (path as NSString).pathExtension))
                    return
                }
                for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { scan(child, depth + 1) }
            } else if url.pathExtension.lowercased() == "zip" {
                let tmp = fm.temporaryDirectory.appendingPathComponent("puckbridge-import-\(UUID().uuidString)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", url.path, tmp.path]
                do { try p.run(); p.waitUntilExit() } catch { errors.append("\(url.lastPathComponent): couldn't unzip it"); return }
                scan(tmp, depth + 1)
                try? fm.removeItem(at: tmp)
            } else if ["png", "webp", "gif", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), depth == 0 || url.deletingPathExtension().lastPathComponent != "preview",
                      let d = try? Data(contentsOf: url) {
                let base = url.deletingPathExtension().lastPathComponent
                let name = base == "spritesheet" ? url.deletingLastPathComponent().lastPathComponent : base
                found.append((CharacterLibrary.clean(name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized), d, url.pathExtension))
            }
        }
        for u in urls { scan(u, 0) }

        var added: [LibraryCharacter] = []
        let existing = Set(all.compactMap { try? Data(contentsOf: $0.sheet) }.map { FirmwareImage.sha([UInt8]($0)) })
        for f in found {
            if existing.contains(FirmwareImage.sha([UInt8](f.data))) { continue }   // already in the library
            do {
                _ = try CustomCharacter.make(data: f.data, name: f.name)
                var slug = f.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                if slug.isEmpty { slug = "character" }
                var dir = libraryDir.appendingPathComponent(slug), n = 2
                while fm.fileExists(atPath: dir.path) { dir = libraryDir.appendingPathComponent("\(slug)-\(n)"); n += 1 }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let sheetName = "spritesheet." + (f.ext.isEmpty ? "png" : f.ext.lowercased())
                try f.data.write(to: dir.appendingPathComponent(sheetName))
                let meta = try JSONSerialization.data(withJSONObject: ["name": f.name, "sheet": sheetName])
                try meta.write(to: dir.appendingPathComponent("character.json"))
                added.append(LibraryCharacter(id: LIB_PREFIX + dir.lastPathComponent, name: f.name, sheet: dir.appendingPathComponent(sheetName), dir: dir))
            } catch {
                errors.append("\(f.name): \(error.localizedDescription)")
            }
        }
        if found.isEmpty && errors.isEmpty { errors.append("No sprite sheets found in what you chose.") }
        reload()
        return (added, errors)
    }

    func remove(_ id: String) {
        if let c = find(id) {
            try? FileManager.default.removeItem(at: c.dir)
            if let cloud = cloudDir { try? FileManager.default.removeItem(at: cloud.appendingPathComponent(c.dir.lastPathComponent)) }
            var seen = Set(UserDefaults.standard.stringArray(forKey: "cloudCharacters") ?? [])
            seen.remove(c.dir.lastPathComponent)
            UserDefaults.standard.set(Array(seen), forKey: "cloudCharacters")
        }
        reload()
    }

    // ---------- iCloud Drive: the same library on every Mac ----------
    // Characters stay private (your iCloud, never this app's repo or releases). Each folder is copied whole: a folder new
    // on either side goes to the other, and a folder this Mac once saw in iCloud that is gone from there now was removed
    // on another Mac, so it goes here too.
    static let cloudRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    var cloudDir: URL? {
        guard Pref.syncCharacters, FileManager.default.fileExists(atPath: CharacterLibrary.cloudRoot.path) else { return nil }
        return CharacterLibrary.cloudRoot.appendingPathComponent("Puck Bridge/Characters")
    }

    /// Folder names holding a readable character.json and its sheet; `pending` = there but not downloaded yet.
    private func folders(_ root: URL, pending: inout Set<String>) -> Set<String> {
        let fm = FileManager.default
        var ready = Set<String>()
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? [] {
            var name = entry.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {   // a whole folder not downloaded yet: ".tiko.icloud"
                name = String(name.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: root.appendingPathComponent(name))
                pending.insert(name)
                continue
            }
            guard !name.hasPrefix("."), (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let meta = entry.appendingPathComponent("character.json")
            if let d = try? Data(contentsOf: meta), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let sheet = j["sheet"] as? String, fm.fileExists(atPath: entry.appendingPathComponent(sheet).path) {
                ready.insert(name)
            } else {
                // Files inside not downloaded yet (".spritesheet.webp.icloud"): ask for them, take it next time.
                for f in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasSuffix(".icloud") {
                    let real = String(f.lastPathComponent.dropFirst().dropLast(".icloud".count))
                    try? fm.startDownloadingUbiquitousItem(at: entry.appendingPathComponent(real))
                }
                pending.insert(name)
            }
        }
        return ready
    }

    func sync() {
        guard let cloud = cloudDir else { return }
        let fm = FileManager.default
        do { try fm.createDirectory(at: cloud, withIntermediateDirectories: true) } catch {
            say("Characters: iCloud Drive isn't reachable (\(error.localizedDescription)); keeping them on this Mac only")
            return
        }
        try? fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        var pending = Set<String>(), ignore = Set<String>()
        let remote = folders(cloud, pending: &pending), local = folders(libraryDir, pending: &ignore)
        var seen = Set(UserDefaults.standard.stringArray(forKey: "cloudCharacters") ?? [])
        // An empty iCloud folder (iCloud Drive just turned on, or off and back) never deletes anything here.
        let cloudEmpty = remote.isEmpty && pending.isEmpty
        var pulled = 0, dropped = 0
        var pushed: Set<String> = []
        for n in remote.subtracting(local) {
            if (try? fm.copyItem(at: cloud.appendingPathComponent(n), to: libraryDir.appendingPathComponent(n))) != nil { pulled += 1 }
        }
        for n in local.subtracting(remote) where !pending.contains(n) {
            if seen.contains(n) && !cloudEmpty {
                // Removed on another Mac. Kept aside, not deleted: a different iCloud account looks the same from here.
                let aside = supportDir.appendingPathComponent("Removed Characters")
                try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
                var to = aside.appendingPathComponent(n), k = 2
                while fm.fileExists(atPath: to.path) { to = aside.appendingPathComponent("\(n)-\(k)"); k += 1 }
                try? fm.moveItem(at: libraryDir.appendingPathComponent(n), to: to); dropped += 1
            } else if (try? fm.copyItem(at: libraryDir.appendingPathComponent(n), to: cloud.appendingPathComponent(n))) != nil {
                pushed.insert(n)
            }
        }
        seen = remote.union(pending).union(pushed)
        UserDefaults.standard.set(Array(seen), forKey: "cloudCharacters")
        if pulled + pushed.count + dropped > 0 {
            say("Characters: iCloud Drive sync (\(pulled) from other Macs, \(pushed.count) shared, \(dropped) removed elsewhere)")
        }
    }

    /// The old single custom character (≤ v0.6) becomes a library entry.
    func migrate() {
        guard let name = Pref.customName, let data = try? Data(contentsOf: customSheetURL) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: tmp)
        let added = importItems([tmp]).added
        try? FileManager.default.removeItem(at: tmp)
        if let c = added.first, Pref.character == CUSTOM_ID { Pref.character = c.id }
        if !added.isEmpty || find(Pref.character) != nil { try? FileManager.default.removeItem(at: customSheetURL); Pref.customName = nil }
    }

    /// The first frame of a sheet, for the Settings window.
    static func preview(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cw = img.width / 8, ch = img.height / 9
        return img.cropping(to: CGRect(x: 0, y: 0, width: cw, height: ch)).map { NSImage(cgImage: $0, size: NSSize(width: cw, height: ch)) }
    }
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
    var libId = ""
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
// MARK: Weather (for the puck's clock face)
// ============================================================================================
// The Mac's location (Location Services) → Open-Meteo (free, no key). Only the rounded latitude/longitude leave
// the Mac, and only to api.open-meteo.com. Refreshed every 30 minutes.
struct WeatherNow { let temp: String; let cond: String; let hilo: String; let at: Date }

final class WeatherService: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    private var location: CLLocation?
    private var current: WeatherNow?
    private let lock = NSLock()
    var onChange: (() -> Void)?
    private(set) var note = ""

    var status: CLAuthorizationStatus { lm.authorizationStatus }
    var allowed: Bool { status == .authorizedAlways || status == .authorized }

    /// What the clock face shows; nil when off, unknown or more than 3 hours old.
    func snapshot() -> WeatherNow? {
        lock.lock(); defer { lock.unlock() }
        guard Pref.weatherOn, let c = current, Date().timeIntervalSince(c.at) < 3 * 3600 else { return nil }
        return c
    }

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        refresh(ask: false)   // the Setup window asks, one permission at a time
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Main thread. Asks for permission the first time.
    func refresh(ask: Bool = true) {
        guard Pref.weatherOn else { setNote(""); return }
        switch status {
        case .notDetermined: if ask { lm.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorized: lm.requestLocation()
        default: setNote("Location is off for Puck Bridge, so the clock shows no weather.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if allowed { manager.requestLocation() }
        onChange?()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        location = l
        fetch(l)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        say("Weather: couldn't get the Mac's location (\(error.localizedDescription))")
        if let l = location { fetch(l) }   // the last known place is fine for weather
    }

    private func setNote(_ n: String) { note = n; onChange?() }

    private func fetch(_ l: CLLocation) {
        let f = Locale.current.measurementSystem == .us
        let lat = String(format: "%.2f", l.coordinate.latitude), lon = String(format: "%.2f", l.coordinate.longitude)
        let q = "latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=1" + (f ? "&temperature_unit=fahrenheit" : "")
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?" + q) else { return }
        URLSession.shared.dataTask(with: url) { data, _, err in
            guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = j["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue else {
                say("Weather: couldn't load (\(err?.localizedDescription ?? "bad response"))")
                DispatchQueue.main.async { self.setNote("Couldn't load the weather just now.") }
                return
            }
            let code = (cur["weather_code"] as? NSNumber)?.intValue ?? -1
            let daily = j["daily"] as? [String: Any]
            let hi = ((daily?["temperature_2m_max"] as? [NSNumber])?.first)?.doubleValue
            let lo = ((daily?["temperature_2m_min"] as? [NSNumber])?.first)?.doubleValue
            func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }
            let w = WeatherNow(temp: deg(t), cond: WeatherService.describe(code),
                               hilo: hi != nil && lo != nil ? "H \(deg(hi!))  L \(deg(lo!))" : "", at: Date())
            self.lock.lock(); self.current = w; self.lock.unlock()
            DispatchQueue.main.async { self.setNote("") }
        }.resume()
    }

    /// WMO weather interpretation codes (Open-Meteo).
    static func describe(_ c: Int) -> String {
        switch c {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Storm with hail"
        default: return ""
        }
    }
}

// ============================================================================================
// MARK: Puck firmware (installed over the cable)
// ============================================================================================
// Puck Bridge's own firmware (the official firmware + firmware/patches: clock face, home button) is built by CI
// and bundled in the app. The official firmware can always be put back: Autonomous publishes it openly.
struct FirmwareImage {
    let version: String
    let data: [UInt8]
    let sha256: String
    let label: String

    static func sha(_ d: [UInt8]) -> String { SHA256.hash(data: Data(d)).map { String(format: "%02x", $0) }.joined() }

    /// The firmware bundled in this build of the app, if any (checked against its own manifest).
    static let bundled: FirmwareImage? = {
        guard let j = Bundle.main.url(forResource: "PuckFirmware", withExtension: "json"),
              let b = Bundle.main.url(forResource: "PuckFirmware", withExtension: "bin"),
              let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: j))) as? [String: Any],
              let version = meta["version"] as? String, let sum = meta["sha256"] as? String,
              let bytes = try? Data(contentsOf: b) else { return nil }
        let data = [UInt8](bytes)
        guard sha(data) == sum.lowercased() else { say("Bundled puck firmware failed its checksum; ignoring it"); return nil }
        return FirmwareImage(version: version, data: data, sha256: sum.lowercased(), label: "Puck Bridge firmware \(version)")
    }()

    static let officialManifest = URL(string: "https://storage.googleapis.com/s3-autonomous-upgrade-3/harness/esp32/ota/metadata.json")!

    /// Downloads the official round-puck firmware Autonomous publishes, verifying size and SHA-256.
    static func official(_ done: @escaping (Result<FirmwareImage, Error>) -> Void) {
        URLSession.shared.dataTask(with: officialManifest) { data, _, err in
            guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c = j["commander"] as? [String: Any], let version = c["version"] as? String,
                  let urlS = c["url"] as? String, let url = URL(string: urlS), let sum = c["sha256"] as? String,
                  let size = (c["size"] as? NSNumber)?.intValue else {
                done(.failure(SimpleError("Couldn't read Autonomous's firmware list (\(err?.localizedDescription ?? "bad response")).")))
                return
            }
            URLSession.shared.dataTask(with: url) { bin, _, err in
                guard let bin = bin else { done(.failure(SimpleError(err?.localizedDescription ?? "Download failed"))); return }
                let bytes = [UInt8](bin)
                guard bytes.count == size, sha(bytes) == sum.lowercased() else {
                    done(.failure(SimpleError("The official firmware download didn't match its checksum."))); return
                }
                done(.success(FirmwareImage(version: version, data: bytes, sha256: sum.lowercased(), label: "official firmware \(version)")))
            }.resume()
        }.resume()
    }
}

final class FwTransfer {
    let image: FirmwareImage
    var offset = 0, acked = 0
    var accepted = false
    var last = Date()
    init(_ image: FirmwareImage) { self.image = image }
}

// ============================================================================================
// MARK: Bridge
// ============================================================================================
let MACHINE_ID = "puck-bridge"
let MACHINE_NAME = Host.current().localizedName ?? "Mac"

struct VoiceTurn { var upload: String; var agentId: String?; var rate: Double; var lang: String; var pcm: [UInt8] }

/// One row on the puck: a Claude Desktop chat or a Claude Code session.
struct PuckItem { let id: String; let name: String; var chat: Chat? = nil; var tile: Tile? = nil }
/// One puck tab ("swarm" in the protocol). The firmware allows 24 tabs of 16 rows each.
struct PuckTab { let id: String; let name: String; let items: [PuckItem] }
let MAX_TABS = 24, MAX_ROWS = 16

/// Cut to the firmware's name buffer (39 bytes) without splitting a character.
func fit(_ s: String, bytes: Int = 39) -> String {
    var out = ""
    for ch in s { if out.utf8.count + String(ch).utf8.count > bytes { break }; out.append(ch) }
    return out
}

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
    var code: [(project: String, items: [ChatItem])] = []
    var puckSettings: PuckSettings?
    var settingsNote = ""
    var petsSupported = false
    var petNote = ""
    var character = Pref.character
    var pbFirmware = 0          // the puck runs Puck Bridge firmware (hello "pb")
    var isPro = false
    var fwNote = ""
    var fwBusy = false
    var timerEnd: Date?
}

/// Settings tiles: the rows of the puck's Settings tab, so settings can be changed on the puck itself.
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

/// A chat Claude is writing in. Kept while the user looks at another chat (Claude Desktop only shows Stop for the chat
/// on screen), so the puck's busy timer doesn't restart from 0 when they come back.
struct BusyChat {
    var since: Date
    var textsBefore: Set<String>   // the conversation before the prompt, to find the reply later
    var labels: Set<String>
    var prompt: String
    var awaySince: Date?           // nil = on screen
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
    // Claude's sidebar shows chats or Code sessions, never both: each list is kept from when it was last on screen.
    var chatRows: [Chat] = []
    var codeRows: [Chat] = Bridge.loadCodeRows()
    /// Claude Code projects in sidebar order, folded ones too (a folded project shows no sessions in the sidebar).
    var codeProjects: [String] = UserDefaults.standard.stringArray(forKey: "codeProjects") ?? []
    var pendingUnfold: (project: String, at: Date)?
    var codeStatuses: Set<String> = []   // the Code status words seen so far (logged once each, to learn them)
    var pendingOpen: (id: String, title: String, at: Date, why: String)?
    var pendingMode: (mode: ClaudeMode, at: Date)?
    var statusBusy: Set<String> = []     // busy because the sidebar status said so (watchCodeStatuses)
    var ambientSent = false              // this connection has had an `ambient` (the puck may be on its clock)
    var modeRequestedAt = Date.distantPast
    var writingNoted = false     // logged once that the writing conversation matches no row
    var focusAfterList = false   // tell the puck which pane is on its face after the next list (connect, tab switch)
    var tabs: [PuckTab] = []
    var pushedTabsKey = ""
    var tabSwitchedAt = Date.distantPast
    var nextPing = Date()
    var nextConnect = Date()
    var lastClaudeRead = Date.distantPast
    var busyNoticeAt = Date.distantPast
    var axTrusted = AXIsProcessTrusted()
    var released = false   // lent to OpenHarness: don't reopen the port

    // writing / finish detection
    var busy: [String: BusyChat] = [:]   // chats Claude is (or was last seen) writing in, shown busy on the puck
    var writingChat: String?             // the one writing on screen right now
    var rawWriting = false, rawStreak = 0
    var nextBusyRefresh = Date.distantFuture
    var pendingStop: (id: String, at: Date)?
    var firstSeen: [String: Date] = [:]
    var seenOnce = false
    var emptyReads = 0
    var claudeReadOnce = false

    // selection + voice
    var openedFromPuck: String?
    var openedAt = Date.distantPast
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

    // firmware + clock face
    var pbFirmware = 0
    var board = ""
    var fwXfer: FwTransfer?
    var fwNote = ""
    var fwExpect = ""          // version we installed, confirmed by the next hello
    var nextAmbient = Date.distantPast
    var weather: WeatherService?

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
                 : claude.app == nil ? "Claude: not running"
                 : "Claude: \(chatRows.count) chats\(Pref.codeTabs ? " · \(codeRows.count) Code sessions" : "")\(view.writing ? " · writing…" : "")"
        s.axTrusted = axTrusted
        s.released = released
        s.writing = view.writing
        s.fw = fw; s.hw = hw
        s.timerEnd = timerLeft != nil ? timerEnd : nil
        s.chats = chatRows.map { ChatItem(id: $0.id, title: $0.title) }
        for c in codeRows {
            let p = c.project ?? "Code", item = ChatItem(id: c.id, title: c.title)
            if let i = s.code.firstIndex(where: { $0.project == p }) { s.code[i].items.append(item) } else { s.code.append((p, [item])) }
        }
        s.puckSettings = s.puckConnected ? puckSettings : nil
        s.settingsNote = settingsNote
        s.petsSupported = petMax >= 1
        s.petNote = petNote
        s.pbFirmware = s.puckConnected ? pbFirmware : 0
        s.isPro = board == "pro"
        s.fwNote = fwNote
        s.fwBusy = fwXfer != nil
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
        port = nil; greeted = false; pushedKey = ""; pushedTabsKey = ""; voice = nil; decoder.reset()
        petXfer = nil; petMapSent = ""; puckSettings = nil; settingsNote = ""
        if fwXfer != nil { fwXfer = nil; fwNote = "The puck disconnected during the install. It keeps its current firmware; try again." }
        pbFirmware = 0
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

    var tiles: [Tile] { puckSettings == nil ? [.character] : Tile.allCases }

    func tileName(_ t: Tile) -> String {
        let s = puckSettings
        switch t {
        case .character: return "Puck character: \(characterName(Pref.character))"
        case .beep: return "Puck beep: " + (s.map { $0.muted ? "Off" : "On" } ?? "?")
        case .brightness: return "Puck brightness: " + (s.map { "\($0.brightness)%" } ?? "?")
        case .calm: return "Puck calm mode: " + (s.map { $0.quiet ? "On" : "Off" } ?? "?")
        }
    }

    // ---------- tabs ----------
    /// Chats, then one tab per Claude Code project in the sidebar's order (its newest 16 sessions), folded projects
    /// included. Settings comes last, for official firmware only (Puck Bridge firmware has its own Settings page).
    func buildTabs() -> [PuckTab] {
        let chats = chatRows.prefix(MAX_ROWS).map { PuckItem(id: $0.id, name: $0.title, chat: $0) }
        var out = [PuckTab(id: "chats", name: "Chats", items: Array(chats))]
        let settings = Pref.puckTiles && pbFirmware < 1
        if Pref.codeTabs {
            for p in projectOrder.prefix(MAX_TABS - 1 - (settings ? 1 : 0)) {
                let rows = codeRows.filter { ($0.project ?? "Code") == p }.prefix(MAX_ROWS)
                out.append(PuckTab(id: Bridge.codeTabId(p), name: p, items: rows.map { PuckItem(id: $0.id, name: $0.title, chat: $0) }))
            }
        }
        if settings {
            out.append(PuckTab(id: "settings", name: "Settings", items: tiles.map { PuckItem(id: $0.id, name: tileName($0), tile: $0) }))
        }
        return out
    }

    /// A Claude Code project's tab id (short and stable: the firmware takes at most 47 bytes).
    static func codeTabId(_ project: String) -> String { "code-" + fnv64(project) }
    static func isCodeTab(_ id: String) -> Bool { id.hasPrefix("code-") }
    /// The project a tab shows, if it's a Code tab.
    func project(ofTab id: String) -> String? { projectOrder.first { Bridge.codeTabId($0) == id } }
    /// The tab a row lives on.
    func tabId(for chat: Chat) -> String { chat.project.map { Bridge.codeTabId($0) } ?? "chats" }

    /// Projects as the sidebar lists them, then any that only remembered sessions name (e.g. "Code").
    var projectOrder: [String] {
        var out = codeProjects
        for c in codeRows { let p = c.project ?? "Code"; if !out.contains(p) { out.append(p) } }
        return out
    }

    /// The Code list to keep after a read of Claude's Code view: what's on screen, plus the remembered sessions of
    /// projects that are folded right now (a folded project shows its name but no sessions). Projects no longer in
    /// the sidebar are forgotten. Sidebar order throughout.
    func mergeCodeRows(visible: [Chat], projects: [String]) -> [Chat] {
        guard !projects.isEmpty else { return visible }   // couldn't see the project groups: trust the rows
        if projects != codeProjects {
            codeProjects = projects
            UserDefaults.standard.set(projects, forKey: "codeProjects")
        }
        var out: [Chat] = []
        for p in projects {
            let shown = visible.filter { $0.project == p }
            out += shown.isEmpty
                ? codeRows.filter { $0.project == p }.map { Chat(id: $0.id, title: $0.title, element: nil, project: p, status: $0.status, label: $0.label) }
                : shown
        }
        out += visible.filter { $0.project == nil || !projects.contains($0.project!) }
        return out
    }

    /// Every row the puck can show, from both of Claude's modes.
    var allRows: [Chat] { chatRows + codeRows }

    static func loadCodeRows() -> [Chat] {
        (UserDefaults.standard.array(forKey: "codeRows") as? [[String]] ?? []).compactMap { r in
            r.count >= 2 ? Chat(id: codeId(project: r[0], title: r[1]), title: r[1], element: nil, project: r[0], status: r.count > 2 ? r[2] : "") : nil
        }
    }
    /// Titles only (no conversation text), so the Code tabs are there before Claude next shows its Code sessions.
    func saveCodeRows() {
        UserDefaults.standard.set(codeRows.prefix(200).map { [$0.project ?? "Code", $0.title, $0.status] }, forKey: "codeRows")
    }

    var currentTab: PuckTab { tabs.first { $0.id == Pref.tab } ?? tabs.first ?? PuckTab(id: "chats", name: "Chats", items: []) }

    /// The tab list. Only sent when a tab is added, removed or renamed (or the selection moves), because
    /// a new list cancels whatever the user is doing on the puck's tab screen.
    func pushTabs(force: Bool = false) {
        let sel = currentTab.id
        // Firmware pb.5 shows each tab's working chats; it takes a new count without disturbing a swipe (only new ids
        // or names do), so the counts are part of the key there.
        let counts = pbFirmware >= 4
        func working(_ t: PuckTab) -> Int { t.items.filter { busy[$0.id] != nil }.count }
        let key = sel + "#" + tabs.map { "\($0.id)=\($0.name)" + (counts ? "=\(working($0))" : "") }.joined(separator: "|")
        if !force && key == pushedTabsKey { return }
        pushedTabsKey = key
        send(["t": "swarms", "selected": sel, "tiles": [Any](),
              "items": tabs.map { t -> [String: Any] in
                  var m: [String: Any] = ["id": t.id, "name": fit(t.name), "agents": t.items.count, "panes": t.items.count]
                  if counts { m["working"] = working(t) }
                  return m
              }])
    }

    /// The rows of the selected tab. `agents.end.tab` must name that tab: it's how the puck confirms a switch.
    func pushChats(force: Bool = false) {
        tabs = buildTabs()
        pushTabs()
        let tab = currentTab
        let eng = engine
        let key = eng + "|" + tab.id + "#" + tab.items.map { "\($0.id)=\($0.name)=\($0.chat?.status ?? "")" }.joined(separator: "|")
        if !force && key == pushedKey { return }
        pushedKey = key
        send(["t": "agents.begin"])
        for i in tab.items {
            var m: [String: Any] = ["t": "agent", "id": i.id, "name": fit(i.name), "engine": eng, "model": "", "effort": "",
                                    "machineId": MACHINE_ID, "machine": MACHINE_NAME]
            if let p = i.chat?.project { m["project"] = fit(p, bytes: 23) }   // Puck Bridge firmware shows it small
            if pbFirmware >= 5, let c = i.chat, c.isCode, let st = Bridge.puckStatus(c.status) {
                m["status"] = fit(st.text, bytes: 23); m["tone"] = st.tone   // "PR #5 merged", purple (firmware pb.6)
            }
            send(m)
        }
        send(["t": "agents.end", "total": tab.items.count, "tab": tab.id])
        // A fresh connection or a new tab has no pane chosen: the puck would show "Choose a pane". Choose one:
        // the chat last opened, else the one open in Claude, else the first.
        // Firmware before pb 3 leaves its clock on any `focus`: after the first `ambient` it has picked a pane itself.
        if focusAfterList, ambientSent && pbFirmware >= 1 && pbFirmware < 3 { focusAfterList = false }
        if focusAfterList, !tab.items.isEmpty {
            focusAfterList = false
            let open = openChatId(view)
            let pick = tab.items.first { $0.id == lastOpenedId } ?? tab.items.first { $0.id == open } ?? tab.items[0]
            send(["t": "focus", "agentId": pick.id, "keepClock": true])   // choose it, but stay on the clock
        }
        // How-to text on each settings tile; `restore` = history, so no beep and nothing in the drawer.
        for t in tab.items.compactMap({ $0.tile }) {
            send(["t": "summary", "agentId": t.id, "name": fit(tileName(t)), "engine": eng, "machine": MACHINE_NAME,
                  "recap": t.help, "text": t.help, "restore": true])
        }
        // Busy chats on other tabs too: the puck remembers tiles it isn't showing, so their timers keep running.
        for id in busy.keys { send(["t": "turn.started", "agentId": id, "text": "Writing…"]) }
    }

    func selectTab(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if id != Pref.tab { say("Puck → tab \"\(tab.name)\"") }
        Pref.tab = id
        tabSwitchedAt = Date()
        focusAfterList = true
        pushTabs(force: true)   // the puck then asks for the tab's rows (agents.refresh)
        // Claude follows, once the swipe settles (swarm.select repeats while swiping): its Chat or Code view, and for
        // a project that's folded in the sidebar, the project unfolded so its sessions can be read and opened.
        if id == "chats" { pendingMode = (.chat, Date()); pendingUnfold = nil }
        if let p = project(ofTab: id) { pendingMode = (.code, Date()); pendingUnfold = (p, Date()) }
    }

    /// Claude's sidebar follows the puck's tab (applied ~1 s after the last swarm.select).
    func applyPendingMode() {
        guard let p = pendingMode, Date().timeIntervalSince(p.at) > 1.0 else { return }
        pendingMode = nil
        guard claude.app != nil, view.mode != .unknown, view.mode != p.mode else { return }
        if writingChat != nil {
            // Switching would take the reply off screen, and its finish could no longer be seen.
            say("Puck switched tabs while Claude is writing; leaving Claude's view as it is")
            return
        }
        if claude.show(p.mode, in: view) { modeRequestedAt = Date() }
    }

    /// Unfold the project picked on the puck once Claude shows its Code view (within a few seconds of the pick).
    func applyPendingUnfold() {
        guard let u = pendingUnfold, pendingMode == nil else { return }
        if Date().timeIntervalSince(u.at) > 6 { pendingUnfold = nil; return }
        guard view.mode == .code, writingChat == nil else { return }
        pendingUnfold = nil
        claude.unfold(u.project, in: view)
    }

    /// The puck opens on the tab for the view Claude shows (and on Chats if the saved tab no longer exists).
    /// True if the tab changed.
    @discardableResult
    func tabToClaudeView() -> Bool {
        let all = buildTabs()
        var id = all.contains(where: { $0.id == Pref.tab }) ? Pref.tab : "chats"
        if Pref.codeTabs, view.mode == .chat { id = "chats" }
        if Pref.codeTabs, view.mode == .code, !Bridge.isCodeTab(id) { id = codeTabForClaude() ?? id }
        guard id != Pref.tab else { return false }
        Pref.tab = id
        return true
    }

    /// Move the puck to the tab holding `chatId` (it was opened from the Mac's menu or by voice) and show it there.
    func moveTab(toCode code: Bool, focus chatId: String) {
        let id = allRows.first { $0.id == chatId }.map { tabId(for: $0) } ?? "chats"
        guard greeted, Pref.codeTabs || !code, id != Pref.tab else { return }
        Pref.tab = id
        tabSwitchedAt = Date()
        tabs = buildTabs()
        pushTabs(force: true)
        pushChats(force: true)
        send(["t": "focus", "agentId": chatId])
    }

    /// The Code tab matching Claude's Code view: the open session's project, else the first project.
    func codeTabForClaude() -> String? {
        if let open = openChatId(view), let c = codeRows.first(where: { $0.id == open }) { return tabId(for: c) }
        return projectOrder.first.map { Bridge.codeTabId($0) }
    }

    /// The puck's tab follows Claude when you switch Claude's view on the Mac.
    func followClaudeMode(_ mode: ClaudeMode) {
        guard greeted, mode != .unknown, Date().timeIntervalSince(modeRequestedAt) > 4, pendingMode == nil else { return }
        if mode == .code && Bridge.isCodeTab(Pref.tab) { return }   // already on a Code project
        guard let id = mode == .code ? codeTabForClaude() : "chats", id != Pref.tab else { return }
        say("Puck → tab \"\(id == "chats" ? "Chats" : project(ofTab: id) ?? "Claude Code")\" (Claude switched views)")
        Pref.tab = id
        tabSwitchedAt = Date()
        focusAfterList = true
        tabs = buildTabs()
        pushTabs(force: true)
        pushChats(force: true)
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
            board = msg["board"] as? String ?? ""
            pbFirmware = msg["pb"] as? Int ?? 0
            if !fwExpect.isEmpty && !greeted {
                fwNote = fw == fwExpect ? "\(fwExpect) is installed and running." : "The puck restarted on \(fw), not \(fwExpect): it kept its previous firmware."
                say("Firmware: puck now runs \(fw)")
                fwExpect = ""
            }
            if let d = msg["settings"] as? [String: Any], let s = PuckSettings(d) { puckSettings = s }
            readPetHello(msg)
            if !greeted {
                greeted = true
                sessionStart = Date()
                focusAfterList = true
                ambientSent = false
                say("Puck connected (firmware \(fw)\(petMax >= 1 ? ", custom characters supported" : ""))")
                // Read Claude now, so the chat list (and its focus) reach the puck before the first `ambient` puts it on
                // its clock; and open the tab that matches Claude's view.
                if !claudeReadOnce && axTrusted && claude.attach() { checkClaude() }
                tabToClaudeView()
                if claudeReadOnce || !axTrusted { tabs = buildTabs(); pushTabs(force: true); pushChats(force: true) }
                send(["t": "notif.replace", "items": [Any]()])
                nextAmbient = .distantPast
                sendSound()
                sendLists()
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
            if greeted { pushChats(); sendMenu() }
            publish()
        case "machines.list":
            send(["t": "machines.begin"])
            send(["t": "machine", "id": MACHINE_ID, "name": MACHINE_NAME, "state": "ready", "local": true])
            send(["t": "machines.end", "selected": MACHINE_ID, "source": "local"])
        case "machine.select":
            send(["t": "machine.selected", "machineId": MACHINE_ID])
        case "agents.list", "agents.refresh":
            pushChats(force: true)
        case "swarms.list":
            tabs = buildTabs(); pushTabs(force: true)
        case "swarm.select":
            if let id = msg["swarmId"] as? String { selectTab(id) }
        case "agent.open":
            if let tile = Tile(id: msg["agentId"] as? String) { tileAct(tile, words: nil, turn: nil) }
            else if let id = msg["agentId"] as? String { openChat(id, why: "tap") }
        case "focus":
            if let id = msg["agentId"] as? String, Tile(id: id) == nil { pendingFocus = (id, Date()) }
            else { pendingFocus = nil }
        case "turn.stop":
            let id = msg["agentId"] as? String
            let v = claude.read()
            if let stop = v.stopButton, id == nil || id == writingChat || openChatId(v) == id {
                say("Puck → stop Claude"); claude.press(stop)
            } else if let id = id, busy[id] != nil, allRows.contains(where: { $0.id == id }) {
                // Writing in a chat that isn't on screen: open it, then press its Stop (see the main loop).
                openChat(id, why: "stop")
                pendingStop = (id, Date())
            } else {
                toast("Claude isn't writing")
            }
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
        case "pb.menu.open":
            sendMenu()
        case "pb.menu.tap":
            if let id = msg["id"] as? String { menuTap(id) }
        case "pb.timer.state":
            if let left = msg["seconds"] as? Int { timerEnd = left > 0 ? Date().addingTimeInterval(Double(left)) : nil; publish() }
        case "pb.timer.done":
            timerEnd = nil
            say("Timer: done (\(msg["reason"] as? String ?? "?"))")
            sendMenu()
            publish()
        case "pb.menu.set":
            if let id = msg["id"] as? String, let i = msg["index"] as? Int { menuSet(id, index: i, value: msg["value"] as? String) }
        case "fw.accept":
            if let x = fwXfer { x.accepted = true; x.last = Date(); fwNote = "Installing… don't unplug the puck."; pumpFw(); publish() }
        case "fw.progress":
            if let x = fwXfer {
                x.acked = msg["written"] as? Int ?? x.acked
                x.last = Date()
                let note = "Installing… \(x.image.data.isEmpty ? 100 : x.acked * 100 / x.image.data.count)% (don't unplug the puck)"
                if note != fwNote { fwNote = note; publish() }
                pumpFw()
            }
        case "fw.done":
            if let x = fwXfer {
                say("Firmware: \(x.image.version) written and verified; the puck is restarting")
                fwExpect = x.image.version
                fwXfer = nil
                fwNote = "Installed. The puck is restarting…"
                publish()
            }
        case "fw.error":
            let m = msg["message"] as? String ?? "no reason given"
            if fwXfer != nil {
                fwXfer = nil
                fwNote = "The puck didn't take the firmware (\(m)). It's still on \(fw)."
                say("Firmware: refused (\(m))")
                syncPets(); publish()
            }
        default:
            break
        }
    }

    // ---------- the puck's own Settings menu (Puck Bridge firmware) ----------
    // The firmware only draws rows and reports taps; each tap moves that setting to its next value here.
    // From firmware pb 2 a row can carry its choices: the puck shows them on a picker page (each character drawn as
    // itself) and reports the one chosen (pb.menu.set).
    /// One choice on a picker page. `pet` draws that engine's character (`builtin`: the firmware's own, even when a
    /// custom pack is mapped to it); `sound` / `volume` make the puck play a preview when the choice is shown (pb 3).
    struct MenuChoice {
        var value: String; var pet: String? = nil; var builtin = false; var sound: String? = nil; var volume: Int? = nil
        init(_ value: String, pet: String? = nil, builtin: Bool = false, sound: String? = nil, volume: Int? = nil) {
            self.value = value; self.pet = pet; self.builtin = builtin; self.sound = sound; self.volume = volume
        }
    }
    struct MenuRow { let id: String; let label: String; let value: String; var choices: [MenuChoice] = []; var index = 0 }
    static let timerMinutes = [1, 3, 5, 10, 15, 25, 30, 45, 60]
    func minutesName(_ m: Int) -> String { m == 60 ? "1 hour" : "\(m) min" }
    var timerLeft: Int? { timerEnd.flatMap { $0 > Date() ? Int($0.timeIntervalSinceNow.rounded()) : nil } }

    static let volumeSteps = [25, 50, 75, 100], brightnessSteps = [20, 40, 60, 80, 100], clockSteps = [0, 2, 5, 10, 15, 30]
    static func nearest(_ list: [Int], _ v: Int) -> Int { list.indices.min { abs(list[$0] - v) < abs(list[$1] - v) } ?? 0 }
    func clockName(_ m: Int) -> String { m == 0 ? "Never" : "\(m) min" }

    var menuRows: [MenuRow] {
        let chars = pickerCharacters
        var character = MenuRow(id: "character", label: "Character", value: characterName(Pref.character))
        character.choices = chars.map { id in
            if !isLibrary(id) { return MenuChoice(characterName(id), pet: id, builtin: true) }
            // An imported character can only be drawn when it is the one on the puck (mapped to "claude").
            let onPuck = custom?.libId == id && custom.map { petHeld.contains($0.id) } == true
            return MenuChoice(characterName(id), pet: onPuck ? "claude" : nil)
        }
        character.index = chars.firstIndex(of: Pref.character) ?? 0
        var rows: [MenuRow] = []
        if pbFirmware >= 3 {
            // Timers count down on the puck itself; the Mac starts and cancels them.
            let left = timerLeft
            var timer = MenuRow(id: "timer", label: "Timer", value: left.map { String(format: "%d:%02d left", $0 / 60, $0 % 60) } ?? "Off")
            timer.choices = Bridge.timerMinutes.map { MenuChoice(minutesName($0)) } + (left != nil ? [MenuChoice("Cancel timer")] : [])
            timer.index = -1   // no `index`: a duration isn't a current value (the puck would mark it green)
            rows.append(timer)
        }
        rows.append(character)
        if let s = puckSettings {
            var sound = MenuRow(id: "sound", label: "Sound", value: s.muted ? "Off" : soundName(Pref.soundStyle))
            sound.choices = [MenuChoice("Off")] + SOUND_STYLES.map { MenuChoice($0.name, sound: $0.id) }
            sound.index = s.muted ? 0 : (SOUND_STYLES.firstIndex { $0.id == Pref.soundStyle } ?? 0) + 1
            var volume = MenuRow(id: "volume", label: "Volume", value: "\(Pref.soundVolume)%")
            volume.choices = Bridge.volumeSteps.map { MenuChoice("\($0)%", volume: $0) }
            volume.index = Bridge.nearest(Bridge.volumeSteps, Pref.soundVolume)
            var bright = MenuRow(id: "brightness", label: "Brightness", value: "\(s.brightness)%")
            bright.choices = Bridge.brightnessSteps.map { MenuChoice("\($0)%") }
            bright.index = Bridge.nearest(Bridge.brightnessSteps, s.brightness)
            rows += [sound, volume, bright, MenuRow(id: "calm", label: "Calm mode", value: s.quiet ? "On" : "Off")]
        }
        var clock = MenuRow(id: "clock", label: "Clock after", value: clockName(Pref.idleMin))
        clock.choices = Bridge.clockSteps.map { MenuChoice(clockName($0)) }
        clock.index = Bridge.nearest(Bridge.clockSteps, Pref.idleMin)
        rows += [clock,
                 MenuRow(id: "clock24", label: "24-hour clock", value: Pref.clock24 ? "On" : "Off"),
                 MenuRow(id: "weather", label: "Weather", value: Pref.weatherOn ? "On" : "Off")]
        if pbFirmware >= 4 {
            // The tenth and last row the firmware takes (UI_PB_MENU_MAX); about 25 of the 512 tokens.
            var lists = MenuRow(id: "lists", label: "Lists", value: listStyleName(Pref.listStyle))
            lists.choices = LIST_STYLES.map { MenuChoice($0.name) }
            lists.index = LIST_STYLES.firstIndex { $0.id == Pref.listStyle } ?? 0
            rows.append(lists)
        }
        if pbFirmware >= 5 {
            // Firmware pb.6 takes 12 rows.
            var theme = MenuRow(id: "theme", label: "Appearance", value: puckThemeName(Pref.puckTheme))
            theme.choices = PUCK_THEMES.map { MenuChoice($0.name) }
            theme.index = PUCK_THEMES.firstIndex { $0.id == Pref.puckTheme } ?? 0
            rows.append(theme)
        }
        return rows
    }

    /// The characters on the puck's picker: 16 at most (the firmware's limit), always including the current one.
    var pickerCharacters: [String] {
        let all = characterChoices
        var shown = Array(all.prefix(16))
        if !shown.contains(Pref.character), all.contains(Pref.character), !shown.isEmpty { shown[shown.count - 1] = Pref.character }
        return shown
    }

    func sendMenu() {
        guard greeted, pbFirmware >= 1 else { return }
        let pickers = pbFirmware >= 2
        send(["t": "pb.menu", "title": "Settings", "items": menuRows.map { r -> [String: Any] in
            var m: [String: Any] = ["id": r.id, "label": r.label, "value": String(r.value.prefix(23))]
            if pickers && !r.choices.isEmpty {
                if r.index >= 0 { m["index"] = r.index }
                m["choices"] = r.choices.map { c -> [String: Any] in
                    var o: [String: Any] = ["value": String(c.value.prefix(23))]
                    if let p = c.pet { o["pet"] = p; if c.builtin { o["builtin"] = true } }
                    if pbFirmware >= 3 {
                        if let snd = c.sound { o["sound"] = snd }
                        if let v = c.volume { o["volume"] = v; o["sound"] = Pref.soundStyle }
                    }
                    return o
                }
            }
            return m
        }])
    }

    /// A choice made on the puck's picker page.
    func menuSet(_ id: String, index: Int, value: String? = nil) {
        switch id {
        case "timer":
            if index >= 0 && index < Bridge.timerMinutes.count {
                let m = Bridge.timerMinutes[index]
                startTimer(minutes: m)
            } else if index == Bridge.timerMinutes.count && timerEnd != nil {
                cancelTimer()
            }
        case "character":
            // By index into the list the puck was sent; its value wins if the list changed since (iCloud refresh).
            let chars = pickerCharacters
            var pick = chars.indices.contains(index) ? chars[index] : nil
            if let v = value, pick.map(characterName) != v { pick = characterChoices.first { characterName($0) == v } }
            if let c = pick, Pref.character != c { Pref.character = c; characterChanged() }
        case "sound":
            guard puckSettings != nil, (0...SOUND_STYLES.count).contains(index) else { break }
            if index == 0 { setPuckSettings(["muted": true]) }
            else {
                Pref.soundStyle = SOUND_STYLES[index - 1].id
                if puckSettings?.muted == true { setPuckSettings(["muted": false]) }
                sendSound(test: true)
            }
        case "volume":
            guard Bridge.volumeSteps.indices.contains(index) else { break }
            Pref.soundVolume = Bridge.volumeSteps[index]; sendSound(test: true)
        case "brightness":
            guard Bridge.brightnessSteps.indices.contains(index) else { break }
            setPuckSettings(["brightness": Bridge.brightnessSteps[index]])
        case "clock":
            guard Bridge.clockSteps.indices.contains(index) else { break }
            Pref.idleMin = Bridge.clockSteps[index]; nextAmbient = .distantPast
        case "lists":
            guard LIST_STYLES.indices.contains(index) else { break }
            Pref.listStyle = LIST_STYLES[index].id; sendLists()
        case "theme":
            guard PUCK_THEMES.indices.contains(index) else { break }
            Pref.puckTheme = PUCK_THEMES[index].id; sendLists()
        default:
            break
        }
        say("Puck menu → \(id) #\(index)")
        sendMenu()
        publish()
    }

    // ---------- timers (they count down on the puck; firmware pb 3) ----------
    var timerEnd: Date?
    func startTimer(minutes m: Int) {
        guard greeted, pbFirmware >= 3 else { return }
        Pref.timerLast = m
        timerEnd = Date().addingTimeInterval(Double(m * 60))
        send(["t": "pb.timer", "seconds": m * 60, "label": "\(minutesName(m)) timer"])
        say("Timer: \(minutesName(m)) on the puck")
        sendMenu()
        publish()
    }
    func cancelTimer() {
        guard greeted, pbFirmware >= 3 else { return }
        timerEnd = nil
        send(["t": "pb.timer", "seconds": 0])
        say("Timer: cancelled")
        sendMenu()
        publish()
    }

    func sendSound(test: Bool = false) {
        guard greeted, pbFirmware >= 1 else { return }
        send(["t": "pb.sound", "style": Pref.soundStyle, "volume": Pref.soundVolume, "test": test])
    }

    /// The puck's list style (firmware pb.5, hello "pb" 4). It keeps it in RAM, so it's sent after every welcome.
    func sendLists() {
        guard greeted, pbFirmware >= 4 else { return }
        var m: [String: Any] = ["t": "pb.ui", "lists": Pref.listStyle]
        if pbFirmware >= 5 { m["theme"] = puckThemeNow() }   // firmware pb.6
        send(m)
        say("Puck lists → \(listStyleName(Pref.listStyle))\(pbFirmware >= 5 ? ", \(puckThemeNow()) theme" : "")")
    }

    func menuTap(_ id: String) {
        func next<T: Equatable>(_ list: [T], after v: T) -> T { list[((list.firstIndex(of: v) ?? -1) + 1) % list.count] }
        switch id {
        case "character":
            let choices = characterChoices
            if !choices.isEmpty { Pref.character = next(choices, after: Pref.character); characterChanged() }
        case "sound":
            // Off → Chime → Soft → Bell → Digital → Off
            guard let s = puckSettings else { break }
            let ids = SOUND_STYLES.map { $0.id }
            if s.muted { Pref.soundStyle = ids[0]; setPuckSettings(["muted": false]); sendSound(test: true) }
            else if Pref.soundStyle == ids.last { setPuckSettings(["muted": true]) }
            else { Pref.soundStyle = next(ids, after: Pref.soundStyle); sendSound(test: true) }
        case "volume":
            Pref.soundVolume = next([25, 50, 75, 100], after: Pref.soundVolume); sendSound(test: true)
        case "brightness":
            if let s = puckSettings { setPuckSettings(["brightness": [20, 40, 60, 80, 100].first { $0 > s.brightness + 2 } ?? 20]) }
        case "calm":
            if let s = puckSettings { setPuckSettings(["quiet": !s.quiet]) }
        case "clock":
            Pref.idleMin = next([0, 2, 5, 10, 15, 30], after: Pref.idleMin); nextAmbient = .distantPast
        case "clock24":
            Pref.clock24.toggle(); nextAmbient = .distantPast
        case "weather":
            Pref.weatherOn.toggle()
            DispatchQueue.main.async { self.weather?.refresh() }
            nextAmbient = .distantPast
        default:
            break
        }
        say("Puck menu → \(id)")
        sendMenu()
        publish()
    }

    // ---------- firmware (over the cable, like OpenHarness does) ----------
    func offerFirmware(_ img: FirmwareImage) {
        guard greeted else { fwNote = "Connect the puck first."; publish(); return }
        guard board != "pro" else { fwNote = "This firmware is for the round puck."; publish(); return }
        guard fwXfer == nil, petXfer == nil else { fwNote = "Another transfer is running; try again in a moment."; publish(); return }
        fwXfer = FwTransfer(img)
        fwNote = "Offering \(img.label) to the puck…"
        say("Firmware: offering \(img.version) (\(img.data.count) bytes)")
        send(["t": "fw.offer", "version": img.version, "size": img.data.count, "sha256": img.sha256])
        publish()
    }

    /// Same flow control as character packs: ≤ 8 KB frames, ≤ 16 KB ahead of the puck's acks.
    private func pumpFw() {
        guard let x = fwXfer, x.accepted else { return }
        while x.offset < x.image.data.count && x.offset - x.acked < 16 * 1024 && port != nil {
            let end = min(x.offset + 8192, x.image.data.count)
            let slice = Array(x.image.data[x.offset..<end])
            x.offset = end
            sendFrame(T_FW, slice)
        }
    }

    // ---------- clock face ----------
    /// Pre-formatted strings for the Puck Bridge firmware's clock face; sent each minute.
    func sendAmbient() {
        ambientSent = true
        let now = Date()
        let f = DateFormatter()
        f.locale = .current
        var time = "", ampm = ""
        if Pref.clock24 {
            f.dateFormat = "HH:mm"; time = f.string(from: now)
        } else {
            f.dateFormat = "h:mm"; time = f.string(from: now)
            f.dateFormat = "a"; ampm = f.string(from: now)
        }
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        let w = weather?.snapshot()
        send(["t": "ambient", "time": time, "ampm": ampm, "date": f.string(from: now),
              "temp": w?.temp ?? "", "cond": w?.cond ?? "", "hilo": w?.hilo ?? "", "idleMin": Pref.idleMin])
        let cal = Calendar.current
        nextAmbient = cal.date(byAdding: .minute, value: 1, to: cal.dateInterval(of: .minute, for: now)?.start ?? now) ?? now.addingTimeInterval(60)
    }

    func openChat(_ id: String, why: String) {
        let v = claude.read()
        if let chat = v.chats.first(where: { $0.id == id }) { opened(chat, why: why); return }
        // On Claude's other mode (or remembered from the last run): switch the sidebar, then open it (finishPendingOpen).
        guard let row = allRows.first(where: { $0.id == id }) else { say("Asked to open a chat that's no longer in the sidebar"); return }
        modeRequestedAt = Date()
        guard claude.show(row.isCode ? .code : .chat, in: v) else {
            if why == "tap" { toast("Couldn't switch Claude to its \(row.isCode ? "Code" : "Chat") list") }
            return
        }
        pendingOpen = (id, row.title, Date(), why)
        if why == "menu" { moveTab(toCode: row.isCode, focus: id) }
    }

    private func opened(_ chat: Chat, why: String) {
        say("Open \"\(chat.title)\" (\(why))")
        openedFromPuck = chat.id
        openedAt = Date()
        lastOpenedId = chat.id
        claude.open(chat, bringForward: Pref.bringForward || why == "menu")
    }

    /// After a mode switch: find the row again (Claude re-draws the list, and chats can get new ids) and open it.
    func finishPendingOpen() {
        guard let p = pendingOpen else { return }
        let v = claude.read()
        let code = p.id.hasPrefix(CODE_PREFIX)
        let project = allRows.first { $0.id == p.id }?.project
        if let c = v.chats.first(where: { $0.id == p.id }) ?? v.chats.first(where: { $0.title == p.title && $0.isCode == code && $0.project == project }) {
            pendingOpen = nil
            opened(c, why: p.why)
        } else if code, let pr = project, claude.unfold(pr, in: v) {
            pendingOpen = (p.id, p.title, Date(), p.why)   // its project was folded: look again once it's open
        } else if Date().timeIntervalSince(p.at) > 4 {
            pendingOpen = nil
            say("Couldn't find \"\(p.title)\" after switching Claude's list")
        }
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
        let id = Pref.character
        say("Character: \(characterName(id))")
        petNote = ""
        if isLibrary(id), custom?.libId != id, let c = CharacterLibrary.shared.find(id) {
            // Convert off the bridge thread, then send it.
            petNote = "Getting \(c.name) ready…"
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: c.sheet), let cc = try? CustomCharacter.make(data: data, name: c.name) else {
                    self.perform { $0.petNote = "Couldn't read \(c.name)'s sprite sheet."; $0.publish() }
                    return
                }
                cc.libId = id
                self.perform { b in
                    guard Pref.character == id else { return }
                    b.custom = cc; b.petFailed[cc.id] = nil; b.syncPets(); b.publish()
                }
            }
        }
        syncPets()
        if greeted { pushChats(); sendMenu() }
        publish()
    }

    /// The characters the puck can show: Fo only exists in newer firmware; imported ones need pet support.
    var characterChoices: [String] {
        BUILTIN_CHARACTERS.filter { $0.id != "fo" || pbFirmware >= 1 }.map { $0.id }
            + (petMax >= 1 ? CharacterLibrary.shared.all.map { $0.id } : [])
    }

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
                if next == nil {
                    next = CharacterLibrary.shared.all.first { c in
                        let n = c.name.lowercased()
                        return heard.contains(n) || !tokens.isDisjoint(with: n.split(separator: " ").map(String.init).filter { $0.count > 2 })
                    }?.id
                }
                guard let n = next, choices.contains(n) else { answer("Say a character's name, like Clawd", ok: false); return }
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
        guard greeted, petMax >= 1, fwXfer == nil else { return }
        let want = isLibrary(Pref.character) && custom?.libId == Pref.character ? custom?.id : nil
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
        let known = allRows.first { $0.id == turn.agentId }
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
                        let target = self.deliver(textOut, to: turn.agentId, known: known, lastOpened: lastOpened)
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
    func deliver(_ words: String, to chatId: String?, known: Chat?, lastOpened: String) -> Chat? {
        var v = claude.read()
        var target: Chat?
        var switched = false
        if let id = chatId {
            var c = v.chats.first { $0.id == id }
            if c == nil, known != nil {
                perform { $0.modeRequestedAt = Date() }   // our switch: the puck's tab doesn't follow it
            }
            if c == nil, let k = known, claude.show(k.isCode ? .code : .chat, in: v) {
                // It's on Claude's other list (chats vs Code sessions): switch, then find it again.
                switched = true
                Thread.sleep(forTimeInterval: 0.9)
                v = claude.read()
                c = v.chats.first { $0.id == id } ?? v.chats.first { $0.title == k.title && $0.isCode == k.isCode && $0.project == k.project }
            }
            if c == nil, let k = known, let p = k.project, claude.unfold(p, in: v) {
                // Its project is folded in the sidebar: unfold it, then find the session.
                Thread.sleep(forTimeInterval: 0.8)
                v = claude.read()
                c = v.chats.first { $0.id == id } ?? v.chats.first { $0.title == k.title && $0.isCode && $0.project == p }
            }
            if let c = c {
                target = c
                if c.id != lastOpened || switched {
                    claude.open(c, bringForward: false)
                    let cid = c.id
                    perform { $0.lastOpenedId = cid; $0.openedFromPuck = cid; $0.openedAt = Date() }
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        // Claude stays where it is (owner, Oct 2026: "only running"): the words are pasted into its message box in the
        // background first. Only if that didn't take does Claude come forward for a moment, and then the app you were
        // using comes back.
        let before = NSWorkspace.shared.frontmostApplication
        let wasFront = before?.bundleIdentifier == CLAUDE_BUNDLE
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
        func commandV(toPid pid: pid_t?) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            if let pid = pid { down?.postToPid(pid); up?.postToPid(pid) }
            else { down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap) }
        }
        // Did the words land? The box's text holds them (its start, as rich text may reflow the rest).
        let probe = String(words.prefix(16))
        func landed() -> Bool { claude.read().composerText.contains(probe) }
        var flashed = false
        if !wasFront, let pid = claude.running?.processIdentifier {
            commandV(toPid: pid)
            Thread.sleep(forTimeInterval: 0.5)
        }
        if wasFront || !landed() {
            if !wasFront { say("Voice: background paste didn't take; bringing Claude forward for a moment") }
            claude.running?.activate()
            // Wait for Claude to really be in front, so ⌘V can't land in another app.
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CLAUDE_BUNDLE {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CLAUDE_BUNDLE else {
                pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) }
                say("Voice: Claude didn't come to the front; not typing"); return target
            }
            flashed = !wasFront
            if let b = claude.read().composer { AXUIElementSetAttributeValue(b, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            Thread.sleep(forTimeInterval: 0.15)
            commandV(toPid: nil)
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            say("Voice: pasted into Claude in the background")
        }
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        defer {
            // Claude came forward only to type: put back the app that was in front.
            if flashed, let b = before { Thread.sleep(forTimeInterval: 0.3); b.activate() }
        }

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
    /// The chat on screen: the one whose title shows in the conversation area (its header). nil = can't tell.
    func openChatId(_ v: ClaudeView) -> String? {
        // The conversation's own title (its web area: "<title> - Claude Code"), when exactly one row has it. The row's
        // text can be cut short or carry its status ("#5 · Merged <title>"), so its button title is checked too.
        // When the conversation has a title, only the title decides: matching its text against other rows' names is
        // how another chat got marked working (owner, Oct 2026).
        if !v.openTitle.isEmpty { return openTitleRow(v) }
        var titles: [String: String] = [:]   // title -> id, only titles no other chat shares
        var dup = Set<String>()
        for c in v.chats {
            let t = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if titles[t] != nil { dup.insert(t) } else { titles[t] = c.id }
        }
        for t in v.mainTexts where !dup.contains(t) { if let id = titles[t] { return id } }
        return nil
    }

    static func squash(_ t: String) -> String {
        t.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
    }
    func openTitleRow(_ v: ClaudeView) -> String? {
        let open = Bridge.squash(v.openTitle)
        guard open.count >= 2 else { return nil }
        let exact = v.chats.filter { Bridge.squash($0.title) == open || Bridge.squash($0.label).hasSuffix(" " + open) }
        if exact.count == 1 { return exact[0].id }
        if exact.count > 1 { return nil }
        // A long title cut short in one place but not the other.
        let near = v.chats.filter { c in
            let t = Bridge.squash(c.title)
            return t.count >= 12 && open.count >= 12 && (t.hasPrefix(open) || open.hasPrefix(t))
        }
        return near.count == 1 ? near[0].id : nil
    }

    func startBusy(_ id: String, prev: ClaudeView, now: Date) {
        if var b = busy[id] {
            if b.awaySince != nil { say("Back on a chat Claude is still writing in") }
            b.awaySince = nil
            busy[id] = b
        } else {
            busy[id] = BusyChat(since: now, textsBefore: Set(prev.mainTexts), labels: prev.messageLabels,
                                prompt: prev.composerText.trimmingCharacters(in: .whitespacesAndNewlines), awaySince: nil)
        }
        send(["t": "turn.started", "agentId": id, "text": "Writing…"])
        nextBusyRefresh = min(nextBusyRefresh, now.addingTimeInterval(10))
    }

    func endBusy(_ id: String) {
        busy[id] = nil
        send(["t": "turn.done", "agentId": id])
        if writingChat == id { writingChat = nil }
    }

    func checkClaude() {
        guard claude.attach() else {
            if !view.chats.isEmpty || !busy.isEmpty {
                say("Claude Desktop isn't running")
                for id in busy.keys { send(["t": "turn.done", "agentId": id]) }
                busy = [:]; writingChat = nil
                view = ClaudeView(); chatRows = []; pushChats(); publish()
            }
            return
        }
        let prev = view
        var cur = claude.read()
        let first = !claudeReadOnce
        claudeReadOnce = true

        if cur.chats.isEmpty && !prev.chats.isEmpty {
            emptyReads += 1
            if emptyReads < 3 { return }
        } else { emptyReads = 0 }

        // Stop has to be there (or gone) on two reads in a row: buttons labelled Stop can flash up while you switch chats.
        // While it's settling (mid-switch), decide nothing: the screen may still be half the old chat.
        rawStreak = cur.writing == rawWriting ? rawStreak + 1 : 1
        rawWriting = cur.writing
        let settled = rawStreak >= 2
        if !settled { cur.writing = prev.writing }

        let now = Date()
        // The sidebar shows one mode's list at a time: keep each list from when it was last on screen. Claude re-draws
        // the list on a switch (chats can come back with new ids) and a Code session's id follows its title.
        let switchedMode = !first && prev.mode != cur.mode
        if cur.mode == .code {
            let merged = mergeCodeRows(visible: cur.chats, projects: cur.projects.map { $0.name })
            carryIds(from: codeRows, to: merged)
            let before = codeRows
            codeRows = merged
            if before.map({ $0.id + $0.status }) != codeRows.map({ $0.id + $0.status }) { saveCodeRows() }
            watchCodeStatuses(codeRows, before: before, now: now)
        } else {
            carryIds(from: chatRows, to: cur.chats)
            chatRows = cur.chats
        }
        if switchedMode {
            say("Claude shows its \(cur.mode == .code ? "Code sessions" : "chats")")
            followClaudeMode(cur.mode)
        } else if first && greeted {
            view = cur
            if tabToClaudeView() { tabs = buildTabs(); pushTabs(force: true); pushChats(force: true) }
        }
        // A row is "new" (a chat started from the home screen) only if it appears while its list is on screen.
        for c in cur.chats where firstSeen[c.id] == nil { firstSeen[c.id] = seenOnce && !switchedMode ? now : .distantPast }
        seenOnce = true
        let open = openChatId(cur)
        func title(_ id: String) -> String { cur.chats.first { $0.id == id }?.title ?? "a chat" }

        if settled && cur.writing {
            // Which chat is writing: the one on screen, else a chat that just appeared (new chat from the home
            // screen), else the one last opened from the puck or menu, else the top row.
            // A wrong guess shows another chat working on the puck (owner, Oct 2026), which is worse than none: when the
            // open conversation has a title that matches no row, nothing is marked.
            var id = open, why = "it's on screen"
            let since = writingChat.flatMap { busy[$0]?.since } ?? now
            let titled = !cur.openTitle.isEmpty
            // A row that "just appeared" counts only at the top of its list or project, where a new chat or session lands
            // (rows that appear lower down were scrolled or expanded into view).
            func topOfGroup(_ c: Chat) -> Bool { cur.chats.first { $0.project == c.project }?.id == c.id }
            if id == nil, let fresh = cur.chats.first(where: { (firstSeen[$0.id] ?? .distantPast) > since.addingTimeInterval(-5) && topOfGroup($0) }) { id = fresh.id; why = "it just appeared" }
            if id == nil, let w = writingChat { id = w; why = "it was writing already" }
            if id == nil, !titled, let o = openedFromPuck, now.timeIntervalSince(openedAt) < 600, cur.chats.contains(where: { $0.id == o }) { id = o; why = "it was opened from the puck" }
            if id == nil && !writingNoted {
                writingNoted = true
                say("Claude is writing in a conversation Puck Bridge can't match to a row\(titled ? " (its title isn't in the sidebar list)" : ""); not marking any chat busy")
            }
            if let id = id, id != writingChat {
                if let old = writingChat {
                    if prev.writing && open == nil, (firstSeen[id] ?? .distantPast) > (busy[old]?.since ?? now).addingTimeInterval(-5) {
                        // The guess was wrong: it's a brand-new chat. Move the busy state over.
                        let b = busy[old]; endBusy(old); busy[id] = b
                    } else {
                        busy[old]?.awaySince = now   // switched from one writing chat to another
                    }
                }
                startBusy(id, prev: prev, now: now)
                writingChat = id
                say("Claude is writing in \"\(title(id))\" (\(why); button \"\(cur.stopLabel)\")")
            }
            if let w = writingChat { busy[w]?.labels.formUnion(cur.messageLabels) }
        } else if settled && prev.writing && writingChat == nil {
            writingNoted = false
        } else if settled && prev.writing, let id = writingChat {
            // Stop went away: finished here, or the user switched to another chat.
            writingChat = nil
            let b = busy[id]
            var stayed: Bool
            if let o = open {
                stayed = o == id
            } else if let b = b {
                let kept = b.textsBefore.intersection(cur.mainTexts).count
                let byText = b.textsBefore.isEmpty ? !cur.mainTexts.isEmpty : Double(kept) / Double(b.textsBefore.count) >= 0.5
                let keptLabels = b.labels.intersection(cur.messageLabels).count
                let byLabels = !b.labels.isEmpty && Double(keptLabels) / Double(b.labels.count) >= 0.5
                let newChat = (firstSeen[id] ?? .distantPast) > b.since.addingTimeInterval(-5)
                stayed = byText || byLabels || newChat
            } else {
                stayed = true
            }
            if stayed {
                endBusy(id)
                notify(cur.chats.first { $0.id == id }, replyText(cur, b))
            } else {
                busy[id]?.awaySince = now
                say("Switched away from \"\(title(id))\" while Claude was writing; it stays busy on the puck")
            }
        }

        // Back on a chat that was busy while you were away, and Claude isn't writing: it finished meanwhile.
        if settled, !cur.writing, let o = open, let b = busy[o], b.awaySince != nil,
           !(Bridge.trustCodeStatus && Bridge.isWorking(cur.chats.first { $0.id == o }?.status ?? "")) {
            endBusy(o)
            // You're looking at it, so no beep: just put the reply on its tile.
            let text = Pref.showReply ? replyText(cur, b) : "Claude finished replying."
            send(["t": "summary", "agentId": o, "name": title(o), "engine": engine, "machine": MACHINE_NAME,
                  "recap": String(text.prefix(190)), "text": String(text.prefix(1500)), "silent": true])
            say("\"\(title(o))\" finished while you were away")
        }
        // Rows that left the sidebar can't be busy any more (only the list on screen can tell).
        for id in busy.keys where id.hasPrefix(CODE_PREFIX) == (cur.mode == .code)
            && !cur.chats.contains(where: { $0.id == id }) && !cur.chats.isEmpty { endBusy(id) }

        let changed = first || switchedMode || cur.chats.map({ $0.id + $0.title }) != view.chats.map({ $0.id + $0.title }) || cur.writing != view.writing
        view = cur
        if greeted { pushChats() }
        if changed { publish() }
    }

    func replyText(_ v: ClaudeView, _ b: BusyChat?) -> String {
        guard let b = b else { return v.lastReply }
        let prompt = b.prompt
        let fresh = v.mainTexts.filter { t in
            !b.textsBefore.contains(t) && !(prompt.count > 3 && (prompt.contains(t) || t.contains(prompt)))
        }
        let joined = fresh.joined(separator: " ")
        return joined.isEmpty ? v.lastReply : joined
    }

    /// Carry state from ids that left the list to the ids that replaced them: the same title after Claude re-drew the
    /// list, or (Code sessions, whose id follows the title) the one session of the same project that was renamed.
    func carryIds(from old: [Chat], to new: [Chat]) {
        let newIds = Set(new.map { $0.id }), oldIds = Set(old.map { $0.id })
        let gone = old.filter { !newIds.contains($0.id) }, added = new.filter { !oldIds.contains($0.id) }
        guard !gone.isEmpty, !added.isEmpty else { return }
        var map: [String: String] = [:]
        for g in gone {
            let same = added.filter { $0.title == g.title && $0.project == g.project }
            if same.count == 1 { map[g.id] = same[0].id }
            else if g.isCode, gone.count == 1, added.count == 1, added[0].project == g.project { map[g.id] = added[0].id }
        }
        for (o, n) in map {
            if let b = busy.removeValue(forKey: o) { busy[n] = b }
            if statusBusy.remove(o) != nil { statusBusy.insert(n) }
            if let f = firstSeen[o] { firstSeen[n] = f }
            if writingChat == o { writingChat = n }
            if lastOpenedId == o { lastOpenedId = n }
            if openedFromPuck == o { openedFromPuck = n }
        }
    }

    /// A Code session's sidebar status as the puck shows it: "#5 · Merged" → ("PR #5 merged", "merged"), "Idle" → ("Idle",
    /// "idle"). The tone picks the colour: merged purple, open green, closed red, anything else grey.
    static func puckStatus(_ raw: String) -> (text: String, tone: String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var pr = "", word = s
        if let m = s.range(of: "^#[0-9]+ · ", options: .regularExpression) {
            pr = s[m].replacingOccurrences(of: " · ", with: "")
            word = String(s[m.upperBound...])
        }
        let w = word.lowercased()
        let tone = ["merged": "merged", "open": "open", "closed": "closed", "draft": "draft", "idle": "idle"][w] ?? ""
        return (pr.isEmpty ? word : "PR \(pr) \(w)", tone)
    }

    /// "#5 · Merged" → "Merged": the part of a Code session's status that isn't its pull request number.
    static func statusWord(_ s: String) -> String {
        s.replacingOccurrences(of: "^#[0-9]+ · ", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    static func isWorking(_ status: String) -> Bool {
        statusWord(status).range(of: "\\b(working|running|thinking|generating|responding|in progress)\\b",
                                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Code sessions keep running when they're not on screen, and their sidebar status may say so. Unverified: which
    /// words Claude uses while a session works (seen so far: Idle, Open, Merged); every new word is logged once.
    /// Off until the words Claude shows while a Code session works are confirmed from a real layout dump: a false
    /// match would show a session working forever.
    static let trustCodeStatus = false
    func watchCodeStatuses(_ rows: [Chat], before: [Chat], now: Date) {
        for r in rows {
            let w = Bridge.statusWord(r.status)
            if !w.isEmpty, codeStatuses.insert(w).inserted { say("Code session status seen: \"\(w)\"") }
        }
        guard Bridge.trustCodeStatus else { return }
        let was = Dictionary(before.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        for r in rows where r.id != writingChat {
            let working = Bridge.isWorking(r.status)
            if working {
                if busy[r.id] == nil {
                    busy[r.id] = BusyChat(since: now, textsBefore: [], labels: [], prompt: "", awaySince: now)
                    statusBusy.insert(r.id)
                    say("A Code session in \(r.project ?? "Code") is working (sidebar)")
                    send(["t": "turn.started", "agentId": r.id, "text": "Working…"])
                    nextBusyRefresh = min(nextBusyRefresh, now.addingTimeInterval(10))
                } else if busy[r.id]?.awaySince != nil {
                    busy[r.id]?.awaySince = now   // still visibly working: don't give up on it
                }
            } else if busy[r.id] != nil, statusBusy.contains(r.id) || was[r.id].map(Bridge.isWorking) == true {
                statusBusy.remove(r.id)
                endBusy(r.id)
                notify(r, "Claude finished in \(r.project ?? "Code").")
            }
        }
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
        let chat = allRows.first { $0.id == lastOpenedId } ?? allRows.first
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
                        } else if type == T_LOG {
                            puckLog(payload)
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
                if Pref.openOnSelect, now.timeIntervalSince(sessionStart) > 3,
                   now.timeIntervalSince(tabSwitchedAt) > 3, f.id != lastOpenedId {
                    openChat(f.id, why: "selected on the puck")
                }
            }
            if greeted && now >= nextPing { send(["t": "ping"]); nextPing = now.addingTimeInterval(10) }
            // The puck forgets a tile is busy 25 s after the last turn.started (ui_prune_stale_busy): keep it fresh so
            // the character keeps working and the small button can still stop Claude.
            if now >= nextBusyRefresh {
                // A chat left in the background can't be watched (Claude Desktop shows nothing for it): stop calling
                // it busy after a while. Coming back to it settles it either way.
                for (id, b) in busy where (b.awaySince.map { now.timeIntervalSince($0) > 20 * 60 } ?? false) {
                    say("Gave up waiting on a chat in the background (20 min)")
                    endBusy(id)
                }
                if greeted { for id in busy.keys { send(["t": "turn.started", "agentId": id, "text": "Writing…"]) } }
                nextBusyRefresh = busy.isEmpty ? .distantFuture : now.addingTimeInterval(10)
            }
            if pendingOpen != nil, now.timeIntervalSince(pendingOpen!.at) > 0.7 { finishPendingOpen() }
            if pendingMode != nil { applyPendingMode() }
            if pendingUnfold != nil { applyPendingUnfold() }
            if let p = pendingStop, now.timeIntervalSince(p.at) > 2.0, pendingOpen == nil {
                pendingStop = nil
                let v = claude.read()
                if let stop = v.stopButton, openChatId(v) == p.id || openChatId(v) == nil && writingChat == p.id {
                    say("Puck → stop Claude"); claude.press(stop)
                } else { toast("Couldn't reach that chat to stop it") }
            }
            if greeted && pbFirmware >= 1 && now >= nextAmbient { sendAmbient() }
            if let x = fwXfer, now.timeIntervalSince(x.last) > (x.accepted ? 20 : 30) {
                fwXfer = nil
                fwNote = x.accepted ? "The install stalled. The puck keeps its current firmware; try again."
                                    : "The puck didn't accept the firmware (it says no while you're talking to it). Try again in a moment."
                say("Firmware: \(x.accepted ? "transfer stalled" : "offer not accepted")")
                syncPets(); publish()
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

    /// The puck's own log lines (frame type 0x04) go into PuckBridge.log, at most 20 a second.
    var puckLogWindow = (start: Date.distantPast, count: 0)
    func puckLog(_ payload: [UInt8]) {
        let now = Date()
        if now.timeIntervalSince(puckLogWindow.start) >= 1 { puckLogWindow = (now, 0) }
        puckLogWindow.count += 1
        guard puckLogWindow.count <= 20 else { return }
        let line = String(decoding: payload.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { say("puck: \(line)") }
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
/// A branch's latest build, published by the Build workflow as the pre-release "preview-<branch>".
struct Preview: Identifiable {
    let id: String          // tag
    let branch: String
    let commit: String
    let version: String
    let summary: String     // the commit's first line
    let signed: Bool
    let date: Date
    let url: URL
}

/// One installable build: a release, or a branch preview.
struct Update { let version: String; let url: URL; let notes: String; let label: String }

final class Updater {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "PBUpdateRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The branch this build is a preview of; empty for a release.
    let channel = (Bundle.main.object(forInfoDictionaryKey: "PBChannel") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let commit = (Bundle.main.object(forInfoDictionaryKey: "PBCommit") as? String ?? "").trimmingCharacters(in: .whitespaces)
    var isPreview: Bool { !channel.isEmpty }
    private(set) var available: Update?

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func get(_ path: String, _ done: @escaping (Any?, String?) -> Void) {
        guard repo.contains("/"), let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else {
            done(nil, "This build has no update repository configured."); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, code == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
                let why = err?.localizedDescription ?? (code == 404 ? "no releases yet" : "HTTP \(code)")
                done(nil, "Couldn't reach GitHub (\(why)).")
                return
            }
            done(json, nil)
        }.resume()
    }

    private static func zipURL(_ release: [String: Any]) -> URL? {
        let assets = release["assets"] as? [[String: Any]] ?? []
        return (assets.first { ($0["name"] as? String) == "PuckBridge.zip" }?["browser_download_url"] as? String).flatMap(URL.init(string:))
    }

    /// The latest release (never a preview).
    func latestRelease(_ done: @escaping (Update?, String?) -> Void) {
        get("releases/latest") { json, error in
            guard let r = json as? [String: Any], let tag = r["tag_name"] as? String, let url = Updater.zipURL(r) else {
                done(nil, error ?? "The latest release has no PuckBridge.zip."); return
            }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            done(Update(version: v, url: url, notes: r["body"] as? String ?? "", label: "v\(v)"), nil)
        }
    }

    /// Every branch preview, newest first.
    func previews(_ done: @escaping ([Preview]?, String?) -> Void) {
        get("releases?per_page=100") { json, error in
            guard let list = json as? [[String: Any]] else { done(nil, error); return }
            let iso = ISO8601DateFormatter()
            let out: [Preview] = list.compactMap { r in
                guard r["prerelease"] as? Bool == true, let tag = r["tag_name"] as? String, tag.hasPrefix("preview-"),
                      let url = Updater.zipURL(r) else { return nil }
                var f: [String: String] = [:]
                for line in (r["body"] as? String ?? "").split(separator: "\n") {
                    if let c = line.firstIndex(of: ":") {
                        f[line[..<c].trimmingCharacters(in: .whitespaces)] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                guard let branch = f["branch"], let commit = f["commit"], let version = f["version"] else { return nil }
                let date = (r["published_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
                return Preview(id: tag, branch: branch, commit: commit, version: version, summary: f["summary"] ?? "",
                               signed: f["signed"] == "true", date: date, url: url)
            }
            done(out.sorted { $0.date > $1.date }, nil)
        }
    }

    /// `done(update, nil)`: something to install; `(nil, nil)`: up to date; `(nil, error)`: couldn't check.
    /// A newer release always wins. With Beta Access, a preview build also follows newer builds of its own branch.
    func check(beta: Bool, done: @escaping (Update?, String?) -> Void) {
        latestRelease { rel, error in
            if let rel = rel, Updater.newer(rel.version, than: self.current) {
                self.available = rel
                say("Updates: \(rel.version) available (running \(self.current))")
                done(rel, nil); return
            }
            guard beta && self.isPreview else { done(nil, rel == nil ? error : nil); return }
            self.previews { list, perror in
                if let p = list?.first(where: { $0.branch == self.channel }), p.commit != self.commit {
                    let u = Update(version: p.version, url: p.url, notes: p.summary, label: "the latest \(p.branch) preview")
                    self.available = u
                    say("Updates: newer preview of \(p.branch) available (\(p.version))")
                    done(u, nil)
                } else {
                    done(nil, list == nil ? perror : nil)
                }
            }
        }
    }

    /// Download, unpack, swap the app in place (keeping the old copy until the new one is in), relaunch.
    func install(_ up: Update, fail: @escaping (String) -> Void) {
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { fail("Can't write to \(parent)."); return }
        say("Updates: downloading \(up.label) (\(up.version))…")
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
    @Published var library: [LibraryCharacter] = []
    @Published var libraryPreviews: [String: NSImage] = [:]
    @Published var customBusy = false
    @Published var customNote = ""
    @Published var updateVersion: String?
    @Published var previews: [Preview] = []
    @Published var previewsNote = ""
    @Published var previewsLoading = false
    @Published var updateNote = ""
    @Published var brightnessDraft: Double?
    @Published var advancedNote = ""
    @Published var weatherNote = ""
    @Published var skipped: Set<SetupStep> = []
    let weather = WeatherService()
    let helper = AccessibilityHelper()
    let signedAs = signingIdentity()
    var onChange: (() -> Void)?
    var showSetup: (() -> Void)?

    init(bridge: Bridge, updater: Updater) {
        self.bridge = bridge
        self.updater = updater
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.refreshLibrary() }
        DispatchQueue.global(qos: .userInitiated).async {
            CharacterLibrary.shared.migrate()
            CharacterLibrary.shared.reload()
            DispatchQueue.main.async {
                self.reloadLibrary()
                if isLibrary(Pref.character) { self.bridge.perform { $0.characterChanged() } }
            }
        }
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

    func reloadLibrary() {
        library = CharacterLibrary.shared.all
        let missing = library.filter { libraryPreviews[$0.id] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let images = missing.compactMap { c in CharacterLibrary.preview(c.sheet).map { (c.id, $0) } }
            DispatchQueue.main.async { for (id, img) in images { self.libraryPreviews[id] = img } }
        }
    }

    func characterDetail(_ c: LibraryCharacter) -> String {
        if !snap.petsSupported && snap.puckConnected { return "This puck's firmware can't hold imported characters." }
        return snap.character == c.id && !snap.petNote.isEmpty ? snap.petNote : "Imported"
    }

    func importCharacters() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .image, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose petdex characters: sprite sheets, folders with pet.json, or .zip files (zips of zips are fine)"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        customBusy = true
        customNote = "Importing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CharacterLibrary.shared.importItems(urls)
            DispatchQueue.main.async {
                self.customBusy = false
                self.reloadLibrary()
                var note = r.added.isEmpty ? "Nothing new added." : "Added \(r.added.map { $0.name }.joined(separator: ", "))."
                if !r.errors.isEmpty { note += " Skipped: " + r.errors.joined(separator: "; ") }
                self.customNote = note
                say("Characters: added \(r.added.count), skipped \(r.errors.count)")
                if r.added.count == 1 { self.choose(r.added[0].id) }
                self.bridge.perform { $0.sendMenu() }
            }
        }
    }

    func setCharacterSync(_ on: Bool) {
        Pref.syncCharacters = on
        objectWillChange.send()
        refreshLibrary()
    }
    /// Pick up characters added or removed on another Mac (iCloud Drive), off the main thread.
    func refreshLibrary() {
        DispatchQueue.global(qos: .utility).async {
            let before = CharacterLibrary.shared.all.map { $0.id }
            CharacterLibrary.shared.reload()
            guard CharacterLibrary.shared.all.map({ $0.id }) != before else { return }
            DispatchQueue.main.async {
                self.reloadLibrary()
                self.bridge.perform { $0.sendMenu() }
            }
        }
    }

    func removeCharacter(_ c: LibraryCharacter) {
        CharacterLibrary.shared.remove(c.id)
        libraryPreviews[c.id] = nil
        reloadLibrary()
        if snap.character == c.id { choose("claude") }
        bridge.perform { b in if b.custom?.libId == c.id { b.custom = nil }; b.syncPets(); b.sendMenu(); b.publish() }
    }

    func refreshPuckList() { bridge.perform { b in if b.greeted { b.pushChats() } } }

    // ---------- clock face + firmware ----------
    var locationAllowed: Bool { weather.allowed }
    func weatherChanged() {
        weatherNote = weather.note
        objectWillChange.send()
        clockChanged()
    }
    /// Re-send the clock strings now (a setting or the weather changed).
    func clockChanged() { bridge.perform { $0.nextAmbient = .distantPast } }
    func allowLocation() {
        if weather.status == .notDetermined { weather.refresh() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    }
    func setWeather(_ on: Bool) { Pref.weatherOn = on; weather.refresh(); weatherChanged() }

    func setPuckTheme(_ id: String) {
        Pref.puckTheme = id
        objectWillChange.send()
        bridge.perform { $0.sendLists(); $0.sendMenu() }
    }

    func setListStyle(_ id: String) {
        Pref.listStyle = id
        objectWillChange.send()
        bridge.perform { $0.sendLists(); $0.sendMenu() }
    }

    func setSound(style: String? = nil, volume: Int? = nil, test: Bool = true) {
        if let s = style { Pref.soundStyle = s }
        if let v = volume { Pref.soundVolume = v }
        objectWillChange.send()
        bridge.perform { $0.sendSound(test: test); $0.sendMenu() }
    }

    func copyClaudeLayout() {
        bridge.perform { b in
            let dump = b.claude.layoutDump()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dump, forType: .string)
                self.advancedNote = "Copied Claude's layout (\(dump.split(separator: "\n").count) lines, no message text). Paste it to whoever is helping you."
            }
        }
    }

    func installFirmware() {
        guard let img = FirmwareImage.bundled else { return }
        let a = NSAlert()
        a.messageText = "Install Puck Bridge firmware \(img.version) on the puck?"
        a.informativeText = """
            Adds a clock and weather face when the puck is idle, and makes the small button a home button \
            (tap: clock · hold while Claude writes: stop · hold otherwise: screen off/on).

            It takes about a minute over the cable. Keep the puck plugged in until it restarts. The puck keeps its \
            previous firmware as a fallback, and Settings → Puck → Restore Official Firmware puts Autonomous's \
            firmware back. (OpenHarness also reinstalls official firmware if it ever connects.)
            """
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        bridge.perform { $0.offerFirmware(img) }
    }
    func restoreOfficialFirmware() {
        let a = NSAlert()
        a.messageText = "Put the official firmware back on the puck?"
        a.informativeText = "Puck Bridge downloads Autonomous's current firmware for the round puck, checks it, and installs it over the cable. The clock face and home button go away."
        a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        snap.fwNote = "Downloading the official firmware…"
        FirmwareImage.official { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let img): self.bridge.perform { $0.offerFirmware(img) }
                case .failure(let e): self.snap.fwNote = ""; self.alert("Couldn't get the official firmware", e.localizedDescription)
                }
            }
        }
    }
    func refreshCode() { bridge.perform { b in if b.greeted { b.pushChats() }; b.publish() } }

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
    var setupSteps: [SetupStep] { Pref.weatherOn ? SetupStep.allCases : [.accessibility, .speech] }
    func granted(_ s: SetupStep) -> Bool {
        switch s {
        case .accessibility: return axTrusted
        case .speech: return speech == .authorized
        case .location: return locationAllowed
        }
    }
    var needsSetup: Bool { setupSteps.contains { !granted($0) } }
    /// System Settings on Accessibility, and the helper card beside it.
    func startAccessibilityHelp() {
        openAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if !AXIsProcessTrusted() { self.helper.show() } }
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
        if interactive, let up = updater.available { confirmInstall(up); return }
        if interactive { updateNote = "Checking…" }
        updater.check(beta: Pref.betaAccess) { up, error in
            DispatchQueue.main.async {
                if let up = up {
                    self.updateVersion = up.version
                    self.updateNote = "\(up.label.prefix(1).uppercased() + up.label.dropFirst()) is available."
                    self.onChange?()
                    if interactive { self.confirmInstall(up) }
                } else if let e = error {
                    self.updateNote = e
                    if interactive { self.alert("Couldn't check for updates", e) }
                } else {
                    self.updateNote = "You're up to date."
                    if interactive {
                        self.alert("You're up to date", self.updater.isPreview
                            ? "This is the newest preview of \(self.updater.channel)."
                            : "Puck Bridge v\(self.updater.current) is the latest release.")
                    }
                }
            }
        }
    }
    private func confirmInstall(_ up: Update) {
        let a = NSAlert()
        a.messageText = "Install \(up.label)?"
        a.informativeText = (up.notes.isEmpty ? "" : String(up.notes.prefix(600)) + "\n\n")
            + "Version \(up.version). The app will restart." + (signedAs == nil ? " You may need to re-allow Accessibility afterwards." : "")
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Later")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            updateNote = "Downloading…"
            updater.install(up) { msg in DispatchQueue.main.async { self.updateNote = ""; self.alert("Update failed", msg) } }
        }
    }

    // ---------- Beta Access ----------
    func loadPreviews() {
        previewsLoading = true
        updater.previews { list, error in
            DispatchQueue.main.async {
                self.previewsLoading = false
                self.previews = list ?? []
                self.previewsNote = list == nil ? (error ?? "") : list!.isEmpty ? "No previews yet. Every branch pushed to GitHub gets one after its build finishes." : ""
            }
        }
    }
    func installPreview(_ p: Preview) {
        let warning = p.signed ? "" : " This one was built before signing was set up, so macOS will ask for permissions again."
        confirmInstall(Update(version: p.version, url: p.url, notes: p.summary + warning, label: "the \(p.branch) preview"))
    }
    func installRelease() {
        updateNote = "Checking…"
        updater.latestRelease { up, error in
            DispatchQueue.main.async {
                self.updateNote = ""
                if let up = up { self.confirmInstall(Update(version: up.version, url: up.url, notes: up.notes, label: "the \(up.label) release")) }
                else { self.alert("Couldn't find the release", error ?? "") }
            }
        }
    }
    var versionLine: String {
        updater.isPreview ? "\(updater.current) · preview of \(updater.channel) (\(updater.commit.prefix(7)))" : updater.current
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
            "Puck Bridge v\(versionLine) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(signedAs.map { "signed as \($0)" } ?? "ad-hoc signed")",
            s.puck + (s.hw.isEmpty ? "" : " · hw \(s.hw)") + (s.pbFirmware >= 1 ? " · Puck Bridge firmware" : "")
                + " · bundled firmware: \(FirmwareImage.bundled?.version ?? "none")",
            "Puck settings: \(ps)",
            "Character: \(characterName(s.character)) (\(s.character))\(s.petsSupported ? "" : " · custom characters not supported")\(s.petNote.isEmpty ? "" : " · \(s.petNote)")",
            s.claude,
            "Accessibility: \(axTrusted ? "allowed" : "NOT allowed") · Speech: \(speech == .authorized ? "allowed" : "not allowed") · Login item: \(loginStatus == .enabled ? "on" : "off")",
            "Open on select: \(Pref.openOnSelect) · Bring forward: \(Pref.bringForward) · Voice sends: \(Pref.voiceSends) · Take puck: \(Pref.takePuck) · Settings tab: \(Pref.puckTiles) · Code tabs: \(Pref.codeTabs)",
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
                if Pref.weatherOn {
                    PermissionRow(title: "Location", detail: "For the weather on the puck's clock face. Only a rounded location goes to Open-Meteo.",
                                  granted: model.locationAllowed, action: model.allowLocation)
                }
                if model.needsSetup {
                    HStack { Spacer(); Button("Walk Me Through It…") { model.showSetup?() } }
                }
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
                LabeledContent("Version", value: model.versionLine)
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
            BetaSection(model: model)
        }
        .formStyle(.grouped)
    }
}

struct BetaSection: View {
    @ObservedObject var model: AppModel
    @AppStorage("betaAccess") private var betaAccess = false
    private static let ago = RelativeDateTimeFormatter()
    var body: some View {
        Section("Beta Access") {
            Toggle("Beta Access: try preview builds of work in progress", isOn: $betaAccess)
                .onChange(of: betaAccess) { _, on in if on { model.loadPreviews() } }
            if model.updater.isPreview {
                HStack {
                    Text("You're running a preview of \(model.updater.channel).").font(.caption)
                    Spacer()
                    Button("Back to the Release…") { model.installRelease() }
                }
            }
            if betaAccess {
                Text("Each branch on GitHub gets a preview build. Previews can be unfinished or broken; you can always go back to the release. While you run a preview, Check for Updates also follows newer builds of that branch.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.previews) { p in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.branch).font(.headline)
                            if !p.summary.isEmpty { Text(p.summary).font(.caption).lineLimit(2) }
                            Text(verbatim: "\(p.version) · \(p.commit.prefix(7)) · built \(Self.ago.localizedString(for: p.date, relativeTo: Date()))\(p.signed ? "" : " · not signed")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.commit == model.updater.commit {
                            Text("Running").foregroundStyle(.secondary)
                        } else {
                            Button("Install…") { model.installPreview(p) }
                        }
                    }
                }
                HStack {
                    Button("Refresh") { model.loadPreviews() }.disabled(model.previewsLoading)
                    if model.previewsLoading { ProgressView().controlSize(.small) }
                    if !model.previewsNote.isEmpty { Text(model.previewsNote).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { if betaAccess && model.previews.isEmpty { model.loadPreviews() } }
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
                    let needsFirmware = c.id == "fo" && model.snap.puckConnected && model.snap.pbFirmware < 1
                    CharacterRow(symbol: c.symbol, name: c.name,
                                 detail: needsFirmware ? "Needs Puck Bridge firmware (Settings → Puck): the official firmware has no Fo." : c.blurb,
                                 image: nil, selected: model.snap.character == c.id) { model.choose(c.id) }
                        .disabled(needsFirmware)
                }
            }
            Section("Your characters") {
                ForEach(model.library) { c in
                    HStack {
                        CharacterRow(symbol: "person.crop.circle", name: c.name, detail: model.characterDetail(c), image: model.libraryPreviews[c.id],
                                     selected: model.snap.character == c.id) { model.choose(c.id) }
                        Button(role: .destructive) { model.removeCharacter(c) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove \(c.name)")
                    }
                }
                HStack {
                    Button("Import Characters…") { model.importCharacters() }.disabled(model.customBusy)
                    if model.customBusy { ProgressView().controlSize(.small) }
                }
                if !model.customNote.isEmpty { Text(model.customNote).font(.caption) }
                Toggle("Keep them in iCloud Drive, the same on all your Macs", isOn: Binding(get: { Pref.syncCharacters }, set: { model.setCharacterSync($0) }))
                Text("Choose petdex characters: sprite sheets (8 × 9 frames, 1536 × 1872 or 768 × 936, PNG or WebP), folders with a pet.json, or .zip files of them. They stay private: on this Mac and, with the switch on, in your iCloud Drive (Puck Bridge → Characters), so importing once is enough for every Mac. The puck gets the one you pick over the cable, again after each restart.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Find characters on petdex.dev", destination: URL(string: "https://petdex.dev")!)
            }
            Section("On the puck") {
                Toggle("Show a Settings tab on the puck", isOn: $puckTiles)
                    .onChange(of: puckTiles) { _, _ in model.refreshPuckList() }
                Text("Hold the puck's face to see its tabs, then pick Settings for Character, Beep, Brightness and Calm mode. Stop on one, then tap the face twice to change it. Or tap, say what you want (\"Jolly\", \"60\", \"off\"), and tap again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct FirmwareSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let s = model.snap
        Section("Firmware") {
            if let img = FirmwareImage.bundled {
                if s.pbFirmware >= 1 && s.fw == img.version {
                    Text("Puck Bridge firmware \(img.version) is on the puck: the clock face and home button are on.")
                } else {
                    HStack {
                        Text(s.pbFirmware >= 1 ? "A newer Puck Bridge firmware is available (\(img.version))." : "Puck Bridge firmware \(img.version)")
                        Spacer()
                        Button(s.pbFirmware >= 1 ? "Update…" : "Install…") { model.installFirmware() }
                            .disabled(!s.puckConnected || s.fwBusy || s.isPro)
                    }
                    Text("Adds a clock and weather face when the puck is idle, and makes the small button a home button: tap for the clock, hold while Claude writes to stop it, hold otherwise to turn the screen off or on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("This build of Puck Bridge doesn't include puck firmware.").foregroundStyle(.secondary)
            }
            HStack {
                Text("Official firmware from Autonomous").foregroundStyle(.secondary)
                Spacer()
                Button("Restore…") { model.restoreOfficialFirmware() }.disabled(!s.puckConnected || s.fwBusy || s.isPro)
            }
            if !s.fwNote.isEmpty { Text(s.fwNote).font(.caption) }
        }
    }
}

struct ClockSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("Clock face") {
            if model.snap.puckConnected && model.snap.pbFirmware < 1 {
                Text("Needs Puck Bridge firmware (above).").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Show the clock when idle for", selection: Binding(get: { Pref.idleMin }, set: { Pref.idleMin = $0; model.clockChanged(); model.objectWillChange.send() })) {
                Text("Never (small button only)").tag(0)
                ForEach([2, 5, 10, 15, 30], id: \.self) { m in Text("\(m) minutes").tag(m) }
            }
            Toggle("24-hour clock", isOn: Binding(get: { Pref.clock24 }, set: { Pref.clock24 = $0; model.clockChanged(); model.objectWillChange.send() }))
            Toggle("Show the weather (uses this Mac's location)", isOn: Binding(get: { Pref.weatherOn }, set: { model.setWeather($0); model.objectWillChange.send() }))
            if Pref.weatherOn && !model.locationAllowed {
                HStack {
                    Text("Location isn't allowed yet.").font(.caption)
                    Spacer()
                    Button("Allow…") { model.allowLocation() }
                }
            }
            if !model.weatherNote.isEmpty { Text(model.weatherNote).font(.caption).foregroundStyle(.secondary) }
        }
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
                    Picker("Chat and tab lists", selection: Binding(get: { Pref.listStyle }, set: { model.setListStyle($0) })) {
                        ForEach(LIST_STYLES, id: \.id) { st in Text(st.name).tag(st.id) }
                    }
                    .disabled(model.snap.pbFirmware < 4)
                    Picker("Appearance", selection: Binding(get: { Pref.puckTheme }, set: { model.setPuckTheme($0) })) {
                        ForEach(PUCK_THEMES, id: \.id) { t in Text(t.name).tag(t.id) }
                    }
                    .disabled(model.snap.pbFirmware < 5)
                    Text(model.snap.pbFirmware >= 4
                         ? "Cards: a column of cards. Dial: the clock's ring, one item at a time. Compact list: five rows at once. Classic: the original green pages. Also on the puck: Settings → Lists."
                         : "Needs Puck Bridge firmware 0.0.88-pb.5 or newer (Firmware, below). Appearance needs pb.6.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sound") {
                    Toggle("Play a sound when Claude finishes a reply", isOn: Binding(get: { !s.muted }, set: { model.setPuck("muted", !$0) }))
                    if model.snap.pbFirmware >= 1 {
                        Picker("Sound", selection: Binding(get: { Pref.soundStyle }, set: { model.setSound(style: $0) })) {
                            ForEach(SOUND_STYLES, id: \.id) { st in Text(st.name).tag(st.id) }
                        }
                        .disabled(s.muted)
                        HStack {
                            Slider(value: Binding(get: { Double(Pref.soundVolume) }, set: { Pref.soundVolume = Int($0); model.objectWillChange.send() }),
                                   in: 10...100, step: 5,
                                   label: { Text(verbatim: "Volume \(Pref.soundVolume)%") },
                                   onEditingChanged: { editing in if !editing { model.setSound() } })
                            Button("Test") { model.setSound() }
                        }
                        .disabled(s.muted)
                    } else {
                        Text("Puck Bridge firmware (below) adds a choice of sounds and a volume control.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.snap.pbFirmware >= 3 {
                    Section("Timer") {
                        HStack {
                            ForEach([1, 5, 10, 25, 60], id: \.self) { m in
                                Button(m == 60 ? "1 h" : "\(m) min") { model.bridge.perform { $0.startTimer(minutes: m) } }
                            }
                            Spacer()
                            if let end = model.snap.timerEnd {
                                Text(timerInterval: Date()...max(Date(), end), countsDown: true).monospacedDigit()
                                Button("Cancel") { model.bridge.perform { $0.cancelTimer() } }
                            }
                        }
                        Text("The puck counts down by itself (also while this Mac sleeps) and rings at the end. You can also start one on the puck: Settings → Timer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
            FirmwareSection(model: model)
            ClockSection(model: model)
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
    @ObservedObject var model: AppModel
    @AppStorage("codeTabs") private var codeTabs = true
    @AppStorage("openOnSelect") private var openOnSelect = true
    @AppStorage("bringForward") private var bringForward = false
    @AppStorage("showReply") private var showReply = true
    @AppStorage("voiceSends") private var voiceSends = true
    var body: some View {
        Form {
            Section("Chats") {
                Toggle("Open a chat in Claude when you stop on it on the puck", isOn: $openOnSelect)
                Toggle("Bring Claude to the front when you open a chat on the puck", isOn: $bringForward)
            }
            Section("Claude Code") {
                Toggle("Show Claude Code sessions as tabs on the puck", isOn: $codeTabs)
                    .onChange(of: codeTabs) { _, _ in model.refreshCode() }
                Text("Hold the puck's face to switch tabs: Chats, then one per Claude Code project, as Claude's sidebar groups them (folded projects too). Open Claude's Code view once so Puck Bridge can see your sessions; it remembers them after that, also when you fold a project. Picking a project on the puck switches Claude to its Code view and unfolds that project.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Button("Copy Claude Layout") { model.copyClaudeLayout() }
                        .help("Claude's window structure (buttons and roles, no message text), for fixing chat detection")
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
            ClaudePane(model: model).tabItem { Label("Claude & Voice", systemImage: "text.bubble") }.tag(SettingsTab.claude)
            AdvancedPane(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }
}

// ---------- first-run setup: one permission at a time ----------
enum SetupStep: Int, CaseIterable, Identifiable { case accessibility, speech, location; var id: Int { rawValue } }

/// A small window that walks through the permissions and moves on by itself as each is granted (AppModel polls them).
struct SetupView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var asked: Set<SetupStep> = []
    var current: SetupStep? { model.setupSteps.first { !model.granted($0) && !model.skipped.contains($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(model.setupSteps) { s in
                    Capsule().fill(model.granted(s) ? Color.green : s == current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            if let step = current { page(step) } else {
                Label("You're all set", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
                Text("Puck Bridge can see Claude, hear the puck and show the weather. macOS remembers this, also after updates.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { close() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 460)
        .onChange(of: current == nil) { _, done in
            if done { model.helper.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { close() } }
        }
    }

    @ViewBuilder func page(_ step: SetupStep) -> some View {
        let n = (model.setupSteps.firstIndex(of: step) ?? 0) + 1
        Text("Step \(n) of \(model.setupSteps.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        switch step {
        case .accessibility:
            Text("Let Puck Bridge see Claude").font(.title2.weight(.semibold))
            Text("This is how it reads your chats, opens them and presses Stop. macOS only lets you switch it on yourself: click the button, then turn on Puck Bridge in the list. A small card beside System Settings shows where.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Puck Bridge")
                Spacer()
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().disabled(true)
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            Text("This window moves on by itself once it's on.").font(.caption).foregroundStyle(.secondary)
            buttons(step, primary: "Open System Settings") { model.startAccessibilityHelp() }
        case .speech:
            Text("Let the puck take your voice").font(.title2.weight(.semibold))
            Text("What you say into the puck is turned into text on this Mac and typed into Claude. Click Allow when macOS asks.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons(step, primary: model.speech == .notDetermined ? "Ask Me" : "Open System Settings") { model.fixSpeech() }
        case .location:
            Text("Weather on the puck's clock").font(.title2.weight(.semibold))
            Text("Puck Bridge uses this Mac's rough location for the forecast (only a rounded position goes to Open-Meteo). Click Allow when macOS asks, or turn the weather off.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn Weather Off") { model.setWeather(false); model.objectWillChange.send() }
                Spacer()
                Button("Skip") { model.skipped.insert(step) }
                Button(model.weather.status == .notDetermined ? "Ask Me" : "Open System Settings") { model.allowLocation() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    func buttons(_ step: SetupStep, primary: String, _ act: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Skip") { model.skipped.insert(step); if step == .accessibility { model.helper.hide() } }
            Button(primary) { asked.insert(step); act() }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The card that floats beside System Settings → Accessibility while the switch is off. Its icon can be dragged into
/// the list (for when macOS didn't add Puck Bridge there itself). It goes away as soon as macOS reports the grant.
final class AccessibilityHelper {
    private var panel: NSPanel?
    private var timer: Timer?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 250),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentViewController = NSHostingController(rootView: HelperCard())
            p.title = "Puck Bridge"
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        place()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            ticks += 1
            if AXIsProcessTrusted() { self.hide(); return }
            if ticks <= 12 { self.place() }   // System Settings may still be opening or moving
            if ticks > 1200 { self.hide() }    // 10 minutes
        }
    }

    func hide() { timer?.invalidate(); timer = nil; panel?.orderOut(nil) }

    /// Right of System Settings' window (its frame is readable without any permission), else left of it, else the
    /// top-right of the screen.
    private func place() {
        guard let p = panel, let main = NSScreen.screens.first else { return }
        let size = p.frame.size
        var origin = NSPoint(x: main.visibleFrame.maxX - size.width - 20, y: main.visibleFrame.maxY - size.height - 20)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let settings = list.first { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.systempreferences"
        }
        if let b = settings?[kCGWindowBounds as String] as? [String: CGFloat],
           let x = b["X"], let y = b["Y"], let w = b["Width"] {
            // Window-server bounds have their origin at the main display's top left; AppKit's at its bottom left.
            let top = main.frame.maxY - y
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: x + 1, y: top - 1)) } ?? main
            origin.y = top - size.height - 40
            if x + w + 12 + size.width <= screen.visibleFrame.maxX { origin.x = x + w + 12 }
            else if x - 12 - size.width >= screen.visibleFrame.minX { origin.x = x - 12 - size.width }
            else { origin.x = x + w - size.width - 16 }
        }
        p.setFrameOrigin(origin)
    }
}

struct HelperCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag into the Accessibility list")
            Text("Turn on Puck Bridge").font(.headline)
            Text("Find Puck Bridge in the list and switch it on. Not in the list? Drag this icon into it.")
                .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Already on but not working? Select it, click −, then drag this icon in again.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 270)
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

        // A permission missing (first run, a new Mac): walk through them, one at a time.
        model.showSetup = { [weak self] in self?.showSetup() }
        if model.needsSetup { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.showSetup() } }

        bridge.weather = model.weather
        model.weather.onChange = { [weak self] in self?.model.weatherChanged() }
        model.weather.start()

        Thread.detachNewThread { [bridge] in bridge.run() }

        // The puck's "Match Mac" appearance follows the Mac's light/dark switch.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [bridge] _ in
            if Pref.puckTheme == "auto" { bridge.perform { $0.sendLists() } }
        }

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
        if model.needsSetup { menu.addItem(add(model.axTrusted ? "Finish Setting Up…" : "⚠︎ Allow Accessibility so Puck Bridge can see Claude…", #selector(allowAccessibility))) }
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
        if !s.code.isEmpty {
            let projects = NSMenu()
            for (project, items) in s.code.prefix(25) {
                let sessions = NSMenu()
                for c in items.prefix(25) {
                    let i = add(c.title, #selector(openChatItem(_:)))
                    i.representedObject = c.id
                    sessions.addItem(i)
                }
                let p = NSMenuItem(title: project, action: nil, keyEquivalent: "")
                p.submenu = sessions
                projects.addItem(p)
            }
            let parent = NSMenuItem(title: "Open Code Session", action: nil, keyEquivalent: "")
            parent.submenu = projects
            menu.addItem(parent)
        }

        let characters = NSMenu()
        var choices = BUILTIN_CHARACTERS.filter { $0.id != "fo" || s.pbFirmware >= 1 || !s.puckConnected }.map { ($0.id, $0.name) }
        choices += model.library.map { ($0.id, $0.name) }
        for (id, name) in choices {
            let i = add(name, #selector(chooseCharacter(_:)))
            i.representedObject = id
            i.state = s.character == id ? .on : .off
            characters.addItem(i)
        }
        characters.addItem(.separator())
        characters.addItem(add("Import Characters…", #selector(openCharacter)))
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
    @objc func allowAccessibility() { showSetup() }

    var setupWindow: NSWindow?
    func showSetup() {
        if setupWindow == nil {
            let host = NSHostingController(rootView: SetupView(model: model, close: { [weak self] in self?.setupWindow?.close() }))
            let w = NSWindow(contentViewController: host)
            w.title = "Set Up Puck Bridge"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            setupWindow = w
        }
        model.skipped = []
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }
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
