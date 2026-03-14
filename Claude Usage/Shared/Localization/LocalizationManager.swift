//
//  LocalizationManager.swift
//  Claude Usage - Centralized Localization System
//
//  Created by Claude Code on 2025-12-27.
//

import Foundation

/// Extension for easy string localization
extension String {
    /// Returns localized string
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }

    /// Returns localized string with format arguments
    func localized(with args: CVarArg...) -> String {
        return String(format: NSLocalizedString(self, comment: ""), arguments: args)
    }

    /// Returns localized string with comment
    func localized(comment: String) -> String {
        return NSLocalizedString(self, comment: comment)
    }
}
