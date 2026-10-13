// Puck Bridge — menu-bar app (https://github.com/mattsinitiere/puckbridge): Harness puck <-> Claude Desktop, no OpenHarness.
//
//   • Recent Claude chats on the puck; select one -> Claude opens it.
//   • Claude finishes a reply in the open chat -> puck beeps + card with the reply's opening.
//   • Tap-and-speak on the puck -> on-device transcription -> typed into the chat (and sent).
//   • Small (bottom) button while Claude is writing -> puck asks "stop?" -> Claude's Stop is pressed.
//   • Auto-connects, survives unplugs and Claude restarts, can start at login.
//
// Puck protocol from the MIT-licensed autonomous-ai/openharness repo (cli/src/cable/*, firmware cable_client.c).

import Cocoa
import ApplicationServices
import Darwin
import Speech
import AVFoundation
import ServiceManagement

// ============================================================================================
// MARK: Settings + log
// ============================================================================================
enum Pref {
    static let d = UserDefaults.standard
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static var openOnSelect: Bool { get { bool("openOnSelect", true) } set { d.set(newValue, forKey: "openOnSelect") } }
    static var voiceSends: Bool { get { bool("voiceSends", true) } set { d.set(newValue, forKey: "voiceSends") } }
    static var takePuck: Bool { get { bool("takePuck", true) } set { d.set(newValue, forKey: "takePuck") } }
}

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PuckBridge.log")
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

// ============================================================================================
// MARK: Puck framing   A5 48 | ver | type | len16 | payload | crc16   (little-endian)
// ============================================================================================
let FRAME_VER: UInt8 = 1
let T_JSON: UInt8 = 0x01, T_PCM: UInt8 = 0x02
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

    func open(_ chat: Chat) {
        running?.activate()
        let r = AXUIElementPerformAction(chat.element, kAXPressAction as CFString)
        if r != .success { say("Couldn't open \"\(chat.title)\" (AX error \(r.rawValue))") }
    }

    func press(_ e: AXUIElement) { _ = AXUIElementPerformAction(e, kAXPressAction as CFString) }
}

// ============================================================================================
// MARK: Claude Code sessions (read-only, from ~/.claude/projects)
// ============================================================================================
// Claude Code keeps one JSONL transcript per session in ~/.claude/projects/<folder>/<session id>.jsonl.
// We read only the first few KB of each (working folder + title) and never log what's in them.
struct CodeSession { let id: String; let title: String; let project: String; let cwd: String; let modified: Date }

final class CodeSessions {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var cache: [String: (modified: Date, session: CodeSession?)] = [:]

    /// Sessions touched in the last `days`, newest first.
    func recent(days: Double = 30) -> [CodeSession] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86400)
        var out: [CodeSession] = []
        var alive = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" && !f.lastPathComponent.hasPrefix("agent-") {
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      m > cutoff else { continue }
                alive.insert(f.path)
                if let c = cache[f.path], c.modified == m { if let s = c.session { out.append(s) }; continue }
                let s = Self.parse(f, modified: m)
                cache[f.path] = (m, s)
                if let s = s { out.append(s) }
            }
        }
        cache = cache.filter { alive.contains($0.key) }
        return out.sorted { $0.modified > $1.modified }
    }

    private static func parse(_ url: URL, modified: Date) -> CodeSession? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        var cwd = "", summary = "", prompt = ""
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
            let type = o["type"] as? String
            if type == "summary", let s = o["summary"] as? String { summary = s }
            if type == "user", prompt.isEmpty, (o["isMeta"] as? Bool) != true, (o["isSidechain"] as? Bool) != true,
               let m = o["message"] as? [String: Any] {
                var t = m["content"] as? String ?? ""
                if t.isEmpty, let parts = m["content"] as? [[String: Any]] {
                    t = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                }
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("Caveat:") { prompt = t }
            }
        }
        let title = (summary.isEmpty ? prompt : summary).replacingOccurrences(of: "\n", with: " ")
        guard !cwd.isEmpty, !title.isEmpty else { return nil }
        return CodeSession(id: url.deletingPathExtension().lastPathComponent, title: String(title.prefix(80)),
                           project: (cwd as NSString).lastPathComponent, cwd: cwd, modified: modified)
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
// MARK: Bridge
// ============================================================================================
let MACHINE_ID = "puck-bridge"
let MACHINE_NAME = Host.current().localizedName ?? "Mac"

struct VoiceTurn { var upload: String; var agentId: String?; var rate: Double; var lang: String; var pcm: [UInt8] }

final class Bridge {
    let claude = Claude()
    let transcriber = Transcriber()
    let deliverQueue = DispatchQueue(label: "puckbridge.deliver")
    var port: Port?
    let decoder = Decoder()
    let sendLock = NSLock()
    var greeted = false
    var fw = ""
    var view = ClaudeView()
    var pushedKey = ""
    var nextPing = Date()
    var lastClaudeRead = Date.distantPast
    var busyNoticeAt = Date.distantPast

    // finish detection
    var orderBeforeWriting: [String] = []
    var labelsWhileWriting: Set<String> = []
    var textsBefore: Set<String> = []
    var promptBefore = ""
    var firstSeen: [String: Date] = [:]
    var seenOnce = false
    var writingStarted = Date.distantPast
    var spinnerChat: String?
    var emptyReads = 0
    var claudeReadOnce = false

    // selection + voice
    var openedFromPuck: String?
    var lastOpenedId = ""
    var pendingFocus: (id: String, at: Date)?
    var sessionStart = Date()
    var voice: VoiceTurn?

    var onStatus: ((String, String) -> Void)?
    private func status() {
        let puck = port == nil ? "Puck: not connected" : greeted ? "Puck: connected (fw \(fw))" : "Puck: connecting…"
        let cl = claude.app == nil ? "Claude: not running" : "Claude: \(view.chats.count) chats\(view.writing ? " · writing…" : "")"
        DispatchQueue.main.async { self.onStatus?(puck, cl) }
    }

    // ---------- puck I/O ----------
    func send(_ msg: [String: Any]) {
        sendLock.lock(); defer { sendLock.unlock() }
        guard let port = port, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        if !port.write(encodeFrame(T_JSON, [UInt8](data))) { dropPuckLocked("write failed") }
    }
    private func dropPuckLocked(_ why: String) {
        if port != nil { say("Puck disconnected (\(why))") }
        port = nil; greeted = false; pushedKey = ""; voice = nil; decoder.reset()
    }
    func dropPuck(_ why: String) { sendLock.lock(); dropPuckLocked(why); sendLock.unlock(); status() }

    func connectPuck() {
        for path in puckPorts() {
            do {
                let p = try Port(path)
                sendLock.lock(); port = p; sendLock.unlock()
                say("Opened \(path)"); status(); return
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

    func pushChats(force: Bool = false) {
        let key = view.chats.map { "\($0.id)=\($0.title)" }.joined(separator: "|")
        if !force && key == pushedKey { return }
        pushedKey = key
        send(["t": "agents.begin"])
        for c in view.chats {
            send(["t": "agent", "id": c.id, "name": c.title, "engine": "claude", "model": "", "effort": "",
                  "machineId": MACHINE_ID, "machine": MACHINE_NAME])
        }
        send(["t": "agents.end", "total": view.chats.count, "tab": "claude"])
        if let s = spinnerChat { send(["t": "turn.started", "agentId": s, "text": "Writing…"]) }
    }

    func toast(_ s: String) { send(["t": "toast", "text": s]) }

    func notify(_ chat: Chat?, _ text: String) {
        let title = chat?.title ?? "Claude"
        let body = text.isEmpty ? "Claude finished replying." : text
        send(["t": "summary", "agentId": chat?.id ?? "claude", "name": title, "engine": "claude",
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
                  "features": ["agents.refresh"]])
            if !greeted {
                greeted = true
                fw = msg["fw"] as? String ?? "?"
                sessionStart = Date()
                say("Puck connected (firmware \(fw))")
                if claudeReadOnce { pushChats(force: true) }
                send(["t": "notif.replace", "items": [Any]()])
                status()
            }
        case "machines.list":
            send(["t": "machines.begin"])
            send(["t": "machine", "id": MACHINE_ID, "name": MACHINE_NAME, "state": "ready", "local": true])
            send(["t": "machines.end", "selected": MACHINE_ID, "source": "local"])
        case "machine.select":
            send(["t": "machine.selected", "machineId": MACHINE_ID])
        case "agents.list", "agents.refresh":
            pushChats(force: true)
        case "agent.open":
            if let id = msg["agentId"] as? String { openChat(id, why: "tap") }
        case "focus":
            if let id = msg["agentId"] as? String { pendingFocus = (id, Date()) }
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
            if let v = voice { voice = nil; finishVoice(v) }
        default:
            break
        }
    }

    func openChat(_ id: String, why: String) {
        let v = claude.read()
        guard let chat = v.chats.first(where: { $0.id == id }) else { say("Puck asked for a chat that's no longer in the sidebar"); return }
        say("Puck → open \"\(chat.title)\" (\(why))")
        openedFromPuck = chat.id
        lastOpenedId = chat.id
        claude.open(chat)
    }

    // ---------- voice ----------
    func finishVoice(_ turn: VoiceTurn) {
        func reply(_ m: [String: Any]) {
            var m = m
            if !turn.upload.isEmpty { m["uploadId"] = turn.upload }
            send(m)
        }
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
                    say("Voice: \"\(textOut)\"")
                    self.deliverQueue.async {
                        let target = self.deliver(textOut, to: turn.agentId)
                        reply(["t": "voice.transcript", "routeId": "", "text": textOut,
                               "agentId": target?.id ?? (turn.agentId ?? "claude"),
                               "agentName": target?.title ?? "Claude", "needsConfirm": false])
                    }
                }
            }
        }
    }

    /// Put the words into Claude's message box (in the chat picked on the puck) and, if enabled, send.
    @discardableResult
    func deliver(_ words: String, to chatId: String?) -> Chat? {
        var v = claude.read()
        var target: Chat?
        if let id = chatId, let c = v.chats.first(where: { $0.id == id }) {
            target = c
            if id != lastOpenedId {
                claude.open(c); lastOpenedId = id; openedFromPuck = id
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        claude.running?.activate()
        Thread.sleep(forTimeInterval: 0.3)
        v = claude.read()
        guard let box = v.composer else { say("Voice: couldn't find Claude's message box"); return target }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.15)

        // Paste (works with Claude's rich text box), then put the clipboard back.
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents(); pb.setString(words, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.5)
        if let s = saved { pb.clearContents(); pb.setString(s, forType: .string) }

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
            if !view.chats.isEmpty { say("Claude Desktop isn't running"); view = ClaudeView(); pushChats(); status() }
            return
        }
        let prev = view
        let cur = claude.read()
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
            spinnerChat = nil
            if byText || byLabels || newChat {
                notify(chat, replyText(cur))
            } else {
                say("Switched chats while Claude was writing (no alert)")
            }
        }
        let changed = cur.chats.count != view.chats.count || cur.writing != view.writing
        view = cur
        if greeted { pushChats() }
        if changed { status() }
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

    // ---------- main loop (background thread) ----------
    func run() {
        say("Puck Bridge started")
        while !AXIsProcessTrusted() {
            DispatchQueue.main.async { self.onStatus?("Needs Accessibility permission", "System Settings → Privacy & Security → Accessibility") }
            sleep(2)
        }
        status()
        while true {
            if port == nil {
                connectPuck()
                if port == nil { sleep(2); tickClaude(); continue }
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
            if let f = pendingFocus, Date().timeIntervalSince(f.at) > 0.8 {
                pendingFocus = nil
                if Pref.openOnSelect, Date().timeIntervalSince(sessionStart) > 3, f.id != lastOpenedId {
                    openChat(f.id, why: "selected on the puck")
                }
            }
            if greeted && Date() >= nextPing { send(["t": "ping"]); nextPing = Date().addingTimeInterval(10) }
            tickClaude()
        }
    }

    func tickClaude() {
        if Date().timeIntervalSince(lastClaudeRead) >= 1.0 { lastClaudeRead = Date(); checkClaude() }
    }
}


// ============================================================================================
// MARK: Updates from GitHub Releases
// ============================================================================================
final class Updater {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "PBUpdateRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    var onAvailable: ((String) -> Void)?
    private(set) var available: (version: String, url: URL, notes: String)?

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Asks GitHub for the latest release. `done(nil)` = up to date or couldn't check (message in log).
    func check(done: @escaping (String?) -> Void) {
        guard repo.contains("/"), let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            say("Updates: no repository configured in this build"); done(nil); return
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
                say("Updates: couldn't check (\(err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"))")
                done(nil); return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Updater.newer(version, than: self.current) {
                self.available = (version, url, json["body"] as? String ?? "")
                say("Updates: \(version) available (running \(self.current))")
                done(version)
            } else {
                done(nil)
            }
        }.resume()
    }

    /// Download, unpack, swap the app in place, relaunch.
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
            let script = "sleep 1; rm -rf \"\(appPath)\"; mv \"\(newApp)\" \"\(appPath)\"; xattr -dr com.apple.quarantine \"\(appPath)\" 2>/dev/null; open \"\(appPath)\""
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
// MARK: Menu-bar app
// ============================================================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = Bridge()
    let updater = Updater()
    var updateItem: NSMenuItem!
    var item: NSStatusItem!
    let puckLine = NSMenuItem(title: "Puck: starting…", action: nil, keyEquivalent: "")
    let claudeLine = NSMenuItem(title: "Claude: …", action: nil, keyEquivalent: "")
    var openOnSelectItem: NSMenuItem!
    var voiceSendsItem: NSMenuItem!
    var takePuckItem: NSMenuItem!
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(connected: false)

        let menu = NSMenu()
        let versionLine = NSMenuItem(title: "Puck Bridge v\(updater.current)", action: nil, keyEquivalent: "")
        menu.addItem(versionLine)
        menu.addItem(puckLine); menu.addItem(claudeLine)
        menu.addItem(.separator())
        openOnSelectItem = add(menu, "Open chats when selected on the puck", #selector(toggleOpenOnSelect))
        voiceSendsItem = add(menu, "Voice: send automatically (off = paste only)", #selector(toggleVoiceSends))
        takePuckItem = add(menu, "Take the puck from OpenHarness automatically", #selector(toggleTakePuck))
        loginItem = add(menu, "Start at login", #selector(toggleLogin))
        menu.addItem(.separator())
        updateItem = add(menu, "Check for updates…", #selector(checkUpdates))
        _ = add(menu, "Restore OpenHarness service", #selector(restoreOpenHarness))
        _ = add(menu, "Open log", #selector(openLog))
        _ = add(menu, "Privacy settings…", #selector(openPrivacy))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Puck Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        refreshChecks()

        bridge.onStatus = { [weak self] puck, claude in
            self?.puckLine.title = puck
            self?.claudeLine.title = claude
            self?.setIcon(connected: puck.hasPrefix("Puck: connected"))
        }

        // Ask for permissions up front so voice works the first time.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        Transcriber.authorize { _ in }

        Thread.detachNewThread { [bridge] in bridge.run() }

        // Quietly check for updates shortly after launch, then once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.autoCheck() }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in self.autoCheck() }
    }

    private func autoCheck() {
        updater.check { v in DispatchQueue.main.async { if let v = v { self.showUpdate(v) } } }
    }
    private func showUpdate(_ v: String) {
        updateItem.title = "Install update v\(v)…"
        setIcon(connected: puckLine.title.hasPrefix("Puck: connected"))
    }
    @objc func checkUpdates() {
        if updater.available != nil { confirmInstall(); return }
        updater.check { v in
            DispatchQueue.main.async {
                if let v = v { self.showUpdate(v); self.confirmInstall() }
                else {
                    let a = NSAlert(); a.messageText = "You're up to date"
                    a.informativeText = "Puck Bridge v\(self.updater.current) is the latest release."
                    if self.updater.repo.isEmpty { a.informativeText = "This build has no update repository configured." }
                    a.runModal()
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
        if a.runModal() == .alertFirstButtonReturn {
            updater.install { msg in
                DispatchQueue.main.async { let e = NSAlert(); e.messageText = "Update failed"; e.informativeText = msg; e.runModal() }
            }
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        return i
    }

    private func setIcon(connected: Bool) {
        let name = connected ? "circle.circle.fill" : "circle.circle"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Puck Bridge")
    }

    private func refreshChecks() {
        openOnSelectItem.state = Pref.openOnSelect ? .on : .off
        voiceSendsItem.state = Pref.voiceSends ? .on : .off
        takePuckItem.state = Pref.takePuck ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleOpenOnSelect() { Pref.openOnSelect.toggle(); refreshChecks() }
    @objc func toggleVoiceSends() { Pref.voiceSends.toggle(); refreshChecks() }
    @objc func toggleTakePuck() { Pref.takePuck.toggle(); refreshChecks() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login setting"
            a.informativeText = "Add Puck Bridge yourself: System Settings → General → Login Items → +.\n\n\(error.localizedDescription)"
            a.runModal()
        }
        refreshChecks()
    }
    @objc func restoreOpenHarness() {
        Pref.takePuck = false; refreshChecks()
        bridge.dropPuck("handing the puck back to OpenHarness")
        startOpenHarness()
        say("OpenHarness service restored; Puck Bridge will no longer take the puck automatically")
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
