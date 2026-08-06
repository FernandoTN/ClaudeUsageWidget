//
//  NetworkMonitor.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor
/// Provides callback when network becomes available
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.claudeusage.networkmonitor")

    /// Current network status
    private(set) var isConnected: Bool = false

    /// Callback triggered when network becomes available
    var onNetworkAvailable: (() -> Void)?

    private init() {}

    /// Starts monitoring network connectivity.
    /// NWPathMonitor.cancel() is terminal — a cancelled instance never
    /// delivers another path update — so every start builds a fresh monitor.
    func startMonitoring() {
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let wasConnected = self.isConnected
            let nowConnected = path.status == .satisfied

            self.isConnected = nowConnected

            // Only fire callback when transitioning from disconnected to connected
            if nowConnected && !wasConnected {
                DispatchQueue.main.async {
                    LoggingService.shared.logInfo("Network became available")
                    self.onNetworkAvailable?()
                }
            }
        }

        monitor.start(queue: queue)
        self.monitor = monitor
    }

    /// Stops monitoring network connectivity
    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }
}
