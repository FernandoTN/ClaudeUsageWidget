//
//  FleetRepaintScheduler.swift
//  Claude Usage
//
//  One coalesced fleet repaint per run-loop turn, held while a profile switch
//  is in flight and released the moment the switch completes.
//
//  Why it exists (incident 2026-09-04 16:38, unified log at ms resolution):
//  the fleet status item paints from the LIVE provider pointers
//  (`ProfileManager.activeAccountIds(among:)`), but nothing in the paint path
//  listened for a pointer MOVING. A switch onto the already-focused profile
//  published an unchanged focus id — dropped by the `removeDuplicates` on
//  `$activeProfile` — so the only paint that ran was the aborted sweep's final
//  one, and it read the Codex pointer 1 ms BEFORE the activation claimed it.
//  The tile kept the previous owner until the 30 s timer fired.
//
//  Two rules, both testable without a status bar:
//
//  1. Every `.providerOwnerClaimed` post — the one signal for "a provider
//     pointer changed", any provider, any cause — requests a paint. N requests
//     inside one turn produce ONE paint on the next.
//  2. No paint lands while `isBlocked()` says a switch is in flight. The
//     request is held and `switchCompleted()` releases it, so a paint can never
//     read a pointer between the credential write and the pointer save and
//     then be the LAST paint. A completed switch always paints, whether or not
//     anything was held: the switch itself is what changed the bar.
//

import Foundation

final class FleetRepaintScheduler {
    /// Why a paint was asked for — reported with the paint so the unified log
    /// can attribute a repaint to its cause.
    enum Reason: String {
        /// A provider pointer moved (`.providerOwnerClaimed`).
        case ownerChanged
        /// A refresh sweep finished while a switch was in flight.
        case sweepEnd
        /// `ProfileManager.isSwitchingProfile` fell back to false.
        case switchCompleted
    }

    typealias Enqueue = (@escaping () -> Void) -> Void

    private let isBlocked: () -> Bool
    private let paint: (Reason) -> Void
    private let enqueue: Enqueue

    /// A flush is already queued for this turn.
    private var pending = false
    /// The reason the queued flush will report — the first one asked for.
    private var queuedReason: Reason?
    /// A flush that found a switch in flight and is waiting for it to end.
    private(set) var heldReason: Reason?
    private var observer: NSObjectProtocol?

    /// Paints performed so far (tests, and the log line's counter).
    private(set) var paintCount = 0

    /// - Parameters:
    ///   - isBlocked: true while a switch is in flight; a flush that finds it
    ///     true holds instead of painting.
    ///   - paint: the actual repaint.
    ///   - enqueue: how "the next run-loop turn" is reached. The default is the
    ///     main queue; tests inject a collector so a turn is explicit.
    init(
        isBlocked: @escaping () -> Bool,
        paint: @escaping (Reason) -> Void,
        enqueue: @escaping Enqueue = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.isBlocked = isBlocked
        self.paint = paint
        self.enqueue = enqueue
    }

    /// Asks for a paint on the next turn. Coalesces: a second request before
    /// the flush runs is absorbed into the first.
    func request(_ reason: Reason) {
        guard !pending else { return }
        pending = true
        queuedReason = reason
        enqueue { [weak self] in self?.flush() }
    }

    /// The switch that was blocking paints has finished. Always paints — the
    /// switch moved what the bar shows even when no pointer request was held.
    func switchCompleted() {
        heldReason = nil
        request(.switchCompleted)
    }

    private func flush() {
        pending = false
        let reason = queuedReason ?? .ownerChanged
        queuedReason = nil
        if isBlocked() {
            heldReason = heldReason ?? reason
            return
        }
        heldReason = nil
        paintCount += 1
        paint(reason)
    }

    // MARK: - Pointer changes

    /// Subscribes to `.providerOwnerClaimed` on `center`. The seam posts from
    /// the main actor (`ProfileManager.setProviderOwner`), synchronously and
    /// only on a real change, so every post here is a pointer that moved.
    func observeOwnerChanges(on center: NotificationCenter = .default) {
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: .providerOwnerClaimed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(.ownerChanged) }
        }
    }

    func stopObserving(on center: NotificationCenter = .default) {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }
}
