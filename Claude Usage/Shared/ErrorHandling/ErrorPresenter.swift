//
//  ErrorPresenter.swift
//  Claude Usage - User-Facing Error Presentation
//
//  Created on 2025-12-27.
//

import SwiftUI
import AppKit

/// Presents errors to users in a friendly way
class ErrorPresenter {

    static let shared = ErrorPresenter()

    private init() {}

    // MARK: - Alert Presentation

    /// Show an error alert to the user
    func showAlert(for error: AppError, in window: NSWindow? = nil) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = error.message
            alert.informativeText = self.buildInformativeText(for: error)
            alert.alertStyle = error.isRecoverable ? .warning : .critical

            // Add buttons
            alert.addButton(withTitle: "OK")

            if error.code.category == .sessionKey || error.code.category == .api {
                alert.addButton(withTitle: "Open Settings")
            }

            alert.addButton(withTitle: "Copy Error Code")

            // Show alert
            if let window = window {
                alert.beginSheetModal(for: window) { response in
                    self.handleAlertResponse(response, error: error)
                }
            } else {
                let response = alert.runModal()
                self.handleAlertResponse(response, error: error)
            }
        }
    }

    private func buildInformativeText(for error: AppError) -> String {
        var text = ""

        if let suggestion = error.recoverySuggestion {
            text += "\(suggestion)\n\n"
        }

        text += "Error Code: \(error.copyableErrorCode)"

        if let details = error.technicalDetails {
            text += "\n\nDetails: \(details)"
        }

        return text
    }

    private func handleAlertResponse(_ response: NSApplication.ModalResponse, error: AppError) {
        switch response {
        case .alertSecondButtonReturn:
            // Open Settings
            NotificationCenter.default.post(name: .openSettings, object: nil)

        case .alertThirdButtonReturn:
            // Copy Error Code
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(error.copyableErrorCode, forType: .string)

            // Show tooltip (optional)
            self.showTooltip("Error code copied to clipboard")

        default:
            break
        }
    }

    private func showTooltip(_ message: String) {
        // For macOS, we can use NSUserNotification or create a custom tooltip window
        // This is a simplified version
        DispatchQueue.main.async {
            // Could implement custom toast window here
            print("📱 Toast: \(message)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}
