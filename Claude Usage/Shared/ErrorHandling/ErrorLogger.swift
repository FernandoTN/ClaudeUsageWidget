//
//  ErrorLogger.swift
//  Claude Usage - Error Logging and Tracking
//
//  Created on 2025-12-27.
//

import Foundation

/// Centralized error logging forwarder (no in-memory ring buffer).
class ErrorLogger {

    static let shared = ErrorLogger()

    private let logQueue = DispatchQueue(label: "com.claude-usage.errorlogger", qos: .utility)

    private init() {}

    // MARK: - Logging

    /// Log an error
    func log(_ error: AppError, severity: ErrorSeverity = .error) {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            let logged = LoggedError(
                error: error,
                severity: severity,
                timestamp: Date()
            )

            // Print to console in debug
            #if DEBUG
            self.printError(logged)
            #endif
        }
    }

    /// Log any error (will wrap it in AppError)
    func log(_ error: Error, severity: ErrorSeverity = .error) {
        let appError = AppError.wrap(error)
        log(appError, severity: severity)
    }

    // MARK: - Private Helpers

    private func printError(_ logged: LoggedError) {
        let icon = logged.severity.icon
        let timestamp = logged.timestamp.formatted(date: .omitted, time: .standard)

        print("\(icon) [\(timestamp)] [\(logged.severity.rawValue.uppercased())] \(logged.error.description)")

        if let context = logged.error.context {
            print("   📍 \(context.fileName):\(context.line) in \(context.function)")
        }

        if logged.error.isRecoverable {
            print("Recoverable")
        } else {
            print("Not Recoverable")
        }

        if let suggestion = logged.error.recoverySuggestion {
            print("   💡 \(suggestion)")
        }
    }
}

// MARK: - Supporting Types

struct LoggedError {
    let error: AppError
    let severity: ErrorSeverity
    let timestamp: Date
}

enum ErrorSeverity: String {
    case debug
    case info
    case warning
    case error
    case critical

    var icon: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🔥"
        }
    }
}
