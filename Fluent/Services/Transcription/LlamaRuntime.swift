import Foundation
import llama

/// Thin entry point into the vendored llama.cpp runtime (Vendor/llama.xcframework).
enum LlamaRuntime {
    /// `llama_backend_init()` must run once per process before any other llama/mtmd call.
    /// A static `let` is initialized lazily and thread-safely exactly once.
    private static let backendInitialized: Void = {
        installLogFilter()
        llama_backend_init()
    }()

    /// Initializes the backend once. Safe to call from any thread, any number of times.
    static func ensureInitialized() {
        _ = backendInitialized
    }

    /// Initializes the backend (once) and returns llama.cpp's system info line,
    /// e.g. which CPU features and the Metal backend are available.
    static func systemInfo() -> String {
        ensureInitialized()
        guard let info = llama_print_system_info() else { return "" }
        return String(cString: info)
    }

    /// llama.cpp and mtmd log every load step and every encode at INFO level on stderr.
    /// Keep warnings and errors in Debug, errors only in Release.
    private static func installLogFilter() {
        let callback: ggml_log_callback = { level, text, _ in
            guard let text else { return }
            #if DEBUG
            let minimum = GGML_LOG_LEVEL_WARN.rawValue
            #else
            let minimum = GGML_LOG_LEVEL_ERROR.rawValue
            #endif
            // CONT lines continue a previous message of unknown level; drop them.
            guard level.rawValue >= minimum, level != GGML_LOG_LEVEL_CONT else { return }
            fputs(text, stderr)
        }
        llama_log_set(callback, nil)
        mtmd_helper_log_set(callback, nil) // also sets mtmd_log_set()
    }
}
