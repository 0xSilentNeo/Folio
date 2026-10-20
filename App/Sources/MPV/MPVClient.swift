import Foundation

/// Values delivered for observed properties.
enum MPVValue: Equatable {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    var bool: Bool? {
        if case .flag(let v) = self { return v }
        return nil
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

enum MPVEvent {
    case property(String, MPVValue)
    case fileLoaded
    case endFile(reason: Int32, error: Int32)
    case playbackRestart
    case seek
    case videoReconfig
    case clientMessage([String])
    case log(prefix: String, level: String, text: String)
    case shutdown
}

protocol MPVClientDelegate: AnyObject {
    func mpvClient(_ client: MPVClient, didReceive event: MPVEvent)
}

/// Thin, thread-safe wrapper around one mpv_handle.
///
/// Lifecycle: `init` (mpv_create) -> set options -> `initialize()` ->
/// commands/properties -> `shutdown()`. The event thread owns the final
/// `mpv_destroy` so the handle is never freed while `mpv_wait_event` is
/// still running on it.
final class MPVClient {
    let handle: OpaquePointer
    weak var delegate: MPVClientDelegate?

    private var eventThread: Thread?
    private let stateLock = NSLock()
    private var _isShutDown = false
    private var shutdownCompletion: (() -> Void)?

    var isShutDown: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isShutDown
    }

    init?() {
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else { return nil }
        handle = h
    }

    // MARK: Options

    @discardableResult
    func setOption(_ name: String, _ value: String) -> Int32 {
        mpv_set_option_string(handle, name, value)
    }

    func initialize(logLevel: String = "info") throws {
        mpv_request_log_messages(handle, logLevel)
        let r = mpv_initialize(handle)
        guard r >= 0 else { throw MPVClientError(code: r) }
        startEventThread()
    }

    // MARK: Commands

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return withCStringArray(args) { mpv_command(handle, $0) }
    }

    @discardableResult
    func commandAsync(_ args: [String], userdata: UInt64 = 0) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return withCStringArray(args) { mpv_command_async(handle, userdata, $0) }
    }

    /// Runs a command string exactly like input.conf / the console does.
    @discardableResult
    func commandString(_ cmd: String) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return mpv_command_string(handle, cmd)
    }

    private func withCStringArray(_ args: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32) -> Int32 {
        var cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }

    // MARK: Properties

    @discardableResult
    func set(_ name: String, _ value: String) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return mpv_set_property_string(handle, name, value)
    }

    @discardableResult
    func set(_ name: String, _ value: Bool) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var v: Int32 = value ? 1 : 0
        return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    @discardableResult
    func set(_ name: String, _ value: Double) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var v = value
        return mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    @discardableResult
    func set(_ name: String, _ value: Int64) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var v = value
        return mpv_set_property(handle, name, MPV_FORMAT_INT64, &v)
    }

    func string(_ name: String) -> String? {
        guard !isShutDown else { return nil }
        guard let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func double(_ name: String) -> Double? {
        guard !isShutDown else { return nil }
        var v: Double = 0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func int(_ name: String) -> Int64? {
        guard !isShutDown else { return nil }
        var v: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 ? v : nil
    }

    func flag(_ name: String) -> Bool? {
        guard !isShutDown else { return nil }
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? (v != 0) : nil
    }

    enum ObserveFormat { case flag, int, double, string, none }

    func observe(_ name: String, _ format: ObserveFormat) {
        let f: mpv_format
        switch format {
        case .flag: f = MPV_FORMAT_FLAG
        case .int: f = MPV_FORMAT_INT64
        case .double: f = MPV_FORMAT_DOUBLE
        case .string: f = MPV_FORMAT_STRING
        case .none: f = MPV_FORMAT_NONE
        }
        mpv_observe_property(handle, 0, name, f)
    }

    func setChapters(_ chapters: [(title: String, time: Double)]) {
        guard !isShutDown else { return }
        let titles = chapters.map { strdup($0.title) }
        defer { titles.forEach { free($0) } }
        var titlePtrs: [UnsafePointer<CChar>?] = titles.map { UnsafePointer($0) }
        var times = chapters.map { $0.time }
        _ = titlePtrs.withUnsafeMutableBufferPointer { tp in
            times.withUnsafeMutableBufferPointer { tm in
                gp_set_chapters(handle, Int32(chapters.count), tp.baseAddress, tm.baseAddress)
            }
        }
    }

    // MARK: Shutdown

    /// Asks the core to quit. The event thread destroys the handle once mpv
    /// reports shutdown, then calls `completion` on the main queue. Any render
    /// context must already be freed before calling this.
    func shutdown(completion: (() -> Void)? = nil) {
        stateLock.lock()
        if _isShutDown { stateLock.unlock(); completion?(); return }
        _isShutDown = true
        shutdownCompletion = completion
        let hasThread = eventThread != nil
        stateLock.unlock()

        if hasThread {
            _ = withCStringArray(["quit"]) { mpv_command_async(handle, 0, $0) }
        } else {
            mpv_terminate_destroy(handle)
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: Event loop

    private func startEventThread() {
        let t = Thread { [unowned self] in self.eventLoop() }
        t.name = "mpv.events"
        t.qualityOfService = .userInitiated
        eventThread = t
        t.start()
    }

    private func eventLoop() {
        while true {
            guard let ev = mpv_wait_event(handle, -1) else { continue }
            let e = ev.pointee
            if e.event_id == MPV_EVENT_NONE { continue }
            if let mapped = Self.map(e) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.mpvClient(self, didReceive: mapped)
                }
            }
            if e.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        stateLock.lock()
        _isShutDown = true
        let completion = shutdownCompletion
        shutdownCompletion = nil
        stateLock.unlock()
        mpv_terminate_destroy(handle)
        DispatchQueue.main.async { completion?() }
    }

    private static func map(_ e: mpv_event) -> MPVEvent? {
        switch e.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = e.data else { return nil }
            let p = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: p.name)
            var value = MPVValue.none
            if let pd = p.data {
                switch p.format {
                case MPV_FORMAT_FLAG: value = .flag(pd.load(as: Int32.self) != 0)
                case MPV_FORMAT_INT64: value = .int(pd.load(as: Int64.self))
                case MPV_FORMAT_DOUBLE: value = .double(pd.load(as: Double.self))
                case MPV_FORMAT_STRING:
                    if let cs = pd.load(as: UnsafePointer<CChar>?.self) { value = .string(String(cString: cs)) }
                default: break
                }
            }
            return .property(name, value)
        case MPV_EVENT_FILE_LOADED: return .fileLoaded
        case MPV_EVENT_END_FILE:
            guard let data = e.data else { return .endFile(reason: -1, error: 0) }
            let ef = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return .endFile(reason: Int32(ef.reason.rawValue), error: ef.error)
        case MPV_EVENT_PLAYBACK_RESTART: return .playbackRestart
        case MPV_EVENT_SEEK: return .seek
        case MPV_EVENT_VIDEO_RECONFIG: return .videoReconfig
        case MPV_EVENT_SHUTDOWN: return .shutdown
        case MPV_EVENT_CLIENT_MESSAGE:
            guard let data = e.data else { return nil }
            let m = data.assumingMemoryBound(to: mpv_event_client_message.self).pointee
            var args: [String] = []
            for i in 0..<Int(m.num_args) {
                if let a = m.args[i] { args.append(String(cString: a)) }
            }
            return .clientMessage(args)
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = e.data else { return nil }
            let m = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            return .log(prefix: String(cString: m.prefix), level: String(cString: m.level), text: String(cString: m.text))
        default:
            return nil
        }
    }
}

struct MPVClientError: Error, LocalizedError {
    let code: Int32
    var errorDescription: String? { String(cString: mpv_error_string(code)) }
}

/// MPV_END_FILE_REASON_* values.
enum MPVEndReason {
    static let eof: Int32 = 0
    static let stop: Int32 = 2
    static let quit: Int32 = 3
    static let error: Int32 = 4
    static let redirect: Int32 = 5
}
