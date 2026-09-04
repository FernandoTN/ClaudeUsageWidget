//
//  MenuBarSummaryRenderer.swift
//  Claude Usage
//
//  Drawing for the fleet-summary layouts (`MenuBarLayout.fleetDots` /
//  `.fleetCounts`): the provider mark, the readiness dots or counts, and the
//  next-candidate row, composed beside an ACTIVE tile that the existing style
//  renderers produce unchanged. Pure drawing — no I/O, no state.
//
//  Visual vocabulary (consult log, docs/specs/menubar-redesign.md §6):
//    filled dot   green / orange / red / purple  measured capacity, suspected
//    hollow ring  grey                           never measured
//    ×            orange                         dead login — needs /login
//    dash         grey                           excluded from auto-switch
//    50 % alpha                                  reading is stale
//    "+N"                                        more accounts than dot slots
//    row 3        91→Mem✓ | Q→Mem? | Q→Mem× (red Q: queue head blocked) | →— | ⇄
//

import Cocoa

extension MenuBarIconRenderer {

    /// Colour of one readiness state on the dark bar. Green/orange/red are the
    /// usage palette; purple is data quality (matches the suspected label
    /// tint); grey is "no information".
    /// The shared colour-role table (`DesignLegend`, round 1 G1): dead is
    /// red, exhausted and near-limit are amber, suspected purple, ready
    /// green; unmeasured / excluded stay the bar's dim grey (the legend's
    /// "informational" resolves against the bar's forced dark appearance).
    nonisolated static func readinessColor(_ readiness: AccountReadiness) -> NSColor {
        switch readiness {
        case .excluded, .unknown: return NSColor(calibratedWhite: 0.72, alpha: 1.0)
        default: return readiness.role.nsColor
        }
    }

    /// Colour of the verdict glyph after the affix.
    nonisolated static func verdictColor(_ verdict: NextCandidate.Verdict) -> NSColor {
        switch verdict {
        case .verified: return DesignRole.ready.nsColor
        case .unverified: return NSColor(calibratedWhite: 0.72, alpha: 1.0)
        case .dead: return DesignRole.blocking.nsColor
        }
    }

    /// Two-letter provider mark. Not `C/X/G`: X is ambiguous between Codex
    /// and xAI.
    nonisolated static func providerMark(_ provider: Profile.ProviderKind) -> String {
        switch provider {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .grok: return "Gk"
        }
    }

    /// Fonts the block draws with — `FleetBlockGeometry`'s reserved widths
    /// were measured with exactly these (and the test re-measures them).
    private static var markFont: NSFont { FleetBlockFonts.mark }
    private static var affixFont: NSFont { FleetBlockFonts.affix }
    private static var countsFont: NSFont { FleetBlockFonts.counts }
    private static let dimText = NSColor(calibratedWhite: 0.72, alpha: 1.0)
    private static let brightText = NSColor(calibratedWhite: 1.0, alpha: 0.9)

    // MARK: - Fleet block

    /// The right-hand block of a provider summary tile: provider mark, the
    /// readiness matrix (dots or counts) in the bar area, and the
    /// next-candidate row underneath. Its width is FIXED by
    /// `FleetBlockGeometry.fleetWidth` for the member count and layout, so
    /// arming or a verdict flip never changes the status item's length.
    /// `height` comes from `FleetBlockGeometry.blockHeight` so the dot row
    /// lands on the active tile's bar and the candidate row on its label row.
    func createFleetBlock(
        summary: ProviderSummary,
        layout: MenuBarLayout,
        height: CGFloat
    ) -> NSImage? {
        let width = FleetBlockGeometry.fleetWidth(memberCount: summary.members.count, layout: layout)
        guard width > 0 else { return nil }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }
        opaqueEventShapeBackdrop(in: image)

        // Provider mark over the provider's TOTAL account count (owner round
        // 2026-09-04, B1: "5 accounts but only 4 showing" — the fifth is the
        // active tile). Two 6 pt rows in the mark column, top-aligned with
        // the dot rows.
        let markAttributes: [NSAttributedString.Key: Any] = [.font: Self.markFont, .foregroundColor: Self.dimText]
        (Self.providerMark(summary.provider) as NSString).draw(at: NSPoint(x: 0, y: height - 7), withAttributes: markAttributes)
        ("\(summary.members.count + (summary.activeId == nil ? 0 : 1))" as NSString).draw(
            at: NSPoint(x: 0, y: height - 14), withAttributes: markAttributes)

        // The matrix is RIGHT-aligned inside the block: the soonest weekly
        // reset sits at the block's right edge, exactly where the
        // every-account layout puts it, whatever the candidate row needs.
        let matrixX = FleetBlockGeometry.markWidth
        switch layout {
        case .fleetCounts:
            drawFleetCounts(summary.counts, at: NSPoint(x: matrixX, y: height - 7.5))
        case .fleetDots, .everyAccount:
            drawFleetDots(summary, originX: matrixX, rightEdge: width, top: height)
        }

        drawCandidateRow(summary, at: NSPoint(x: matrixX, y: 0), available: width - matrixX)
        return image
    }

    /// One 4 pt mark per OTHER account in paint order. Filled COLUMN-major
    /// from the RIGHT edge (the two soonest resets share the rightmost
    /// column, top first), so the wrap never moves "next to burn" off the
    /// right edge; a `+N` for the rest takes the leftmost column.
    private func drawFleetDots(_ summary: ProviderSummary, originX: CGFloat, rightEdge: CGFloat, top: CGFloat) {
        let (shown, overflow) = summary.dotMembers()
        let d = FleetBlockGeometry.dotDiameter
        let grid = FleetBlockGeometry.dotGrid(count: shown.count)
        var leftmostX = rightEdge
        for (i, member) in shown.enumerated() {
            // j counts from the soonest (last) member: 0 = rightmost column, top.
            let j = shown.count - 1 - i
            let col = j / grid.rows
            let row = j % grid.rows
            let x = rightEdge - d - CGFloat(col) * FleetBlockGeometry.dotPitch
            let y = top - d - CGFloat(row) * FleetBlockGeometry.rowPitch
            let rect = NSRect(x: x, y: y, width: d, height: d)
            leftmostX = min(leftmostX, x)
            let color = Self.readinessColor(member.readiness)
                .withAlphaComponent(member.isStale ? 0.5 : 1.0)
            switch member.readiness {
            case .unknown:
                color.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            case .dead:
                color.setStroke()
                let cross = NSBezierPath()
                cross.lineWidth = 1.2
                cross.move(to: NSPoint(x: rect.minX, y: rect.minY))
                cross.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                cross.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                cross.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                cross.stroke()
            case .excluded:
                color.setFill()
                NSRect(x: rect.minX, y: rect.midY - 0.5, width: d, height: 1).fill()
            case .ready, .readyLight, .sessionHit, .sessionHitLight, .weeklyHitSoon, .weeklyHit, .suspected:
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
        }
        if overflow > 0 {
            // Two reserved columns left of the matrix plus a gap — the
            // latest-reset end of the ranking, the least decision-relevant
            // one — on the LAST row, dimmed, so it never competes with the
            // dead marks beside it (round 1, B3). `+17` at 6 pt is 11 pt.
            let x = max(originX, leftmostX - CGFloat(FleetBlockGeometry.overflowColumns) * FleetBlockGeometry.dotPitch
                        - FleetBlockGeometry.overflowGap)
            // On the TOP row: the bottom row of the mark column now carries
            // the account count, and "25 +6" read as one number.
            ("+\(overflow)" as NSString).draw(
                at: NSPoint(x: x, y: top - d - 1.5),
                withAttributes: [.font: Self.markFont, .foregroundColor: Self.dimText.withAlphaComponent(0.7)]
            )
        }
    }

    /// ONE row in the bar area: `●` ready, `◐` low, `▲` exhausted, `×` dead,
    /// each cell as wide as its text. States are never merged — low is still
    /// a valid switch target, exhausted is not; unknown / suspected /
    /// excluded stay out of the counts (neither capacity nor its absence).
    /// One row, not two: the candidate row owns the bottom of the block and
    /// a second counts row would collide with it in 22 pt.
    private func drawFleetCounts(_ counts: [AccountReadiness: Int], at origin: NSPoint) {
        // The canonical glyph set (`DesignGlyph`): the two shades of a colour
        // share a cell (● greens, ◐ oranges, ▲ reds, × dead).
        let cells: [(glyph: String, states: [AccountReadiness], tint: AccountReadiness)] = [
            (DesignGlyph.ready, [.ready, .readyLight], .ready),
            (DesignGlyph.sessionHit, [.sessionHit, .sessionHitLight], .sessionHit),
            (DesignGlyph.weeklyHit, [.weeklyHit, .weeklyHitSoon], .weeklyHit),
            (DesignGlyph.dead, [.dead], .dead),
        ]
        var x = origin.x
        for cell in cells {
            let n = cell.states.reduce(0) { $0 + counts[$1, default: 0] }
            guard n > 0 else { continue }
            let text = "\(cell.glyph)\(n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.countsFont, .foregroundColor: Self.readinessColor(cell.tint),
            ]
            text.draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
            x += text.size(withAttributes: attributes).width + 2
        }
    }

    /// Row 3: the active account's digits (tinted by ITS evidence), the
    /// arrow (tinted by the QUEUE state: white ranked, accent queued, red
    /// when the queue head is blocked and this is the fallback), the
    /// candidate's name (tinted by its quota evidence) and the verdict glyph
    /// (tinted by the login evidence), each segment separated by
    /// `FleetBlockGeometry.candidateGap` (round 1, B2/B4). Nothing while idle.
    private func drawCandidateRow(_ summary: ProviderSummary, at origin: NSPoint, available: CGFloat) {
        guard let affix = summary.affix else { return }
        // Nothing is reserved for this row (owner, 2026-09-04): the full row
        // when the block is wide enough, the arrow and tag when only that
        // fits, nothing when neither does — the ⇄ menu carries it. The
        // width of the block never depends on this decision.
        let full = available >= FleetBlockGeometry.affixWidth
        let compressed = !full && available >= FleetBlockGeometry.affixCompressedWidth
        guard full || compressed || summary.next == nil || summary.isSwitching else { return }
        var x = origin.x
        func draw(_ string: String, _ color: NSColor, gapAfter: CGFloat = FleetBlockGeometry.candidateGap) {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.affixFont, .foregroundColor: color]
            (string as NSString).draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
            x += (string as NSString).size(withAttributes: attributes).width + gapAfter
        }
        if let digits = summary.activeDigits, !summary.isSwitching, full {
            let color: NSColor
            switch summary.activeReadiness {
            case .suspected?: color = DesignRole.suspected.nsColor
            case .weeklyHit?, .weeklyHitSoon?: color = StatusBarUIManager.weeklyMaxedLabelColor
            case .sessionHit?, .sessionHitLight?: color = DesignRole.caution.nsColor
            default: color = Self.brightText
            }
            draw("\(digits)", color)
        }
        if let next = summary.next, !summary.isSwitching {
            let arrowColor: NSColor = next.queueHeadBlocked
                ? DesignRole.blocking.nsColor
                : (next.queued ? DesignRole.action.nsColor : Self.brightText)
            draw(DesignGlyph.next, arrowColor, gapAfter: 0)
            let labelColor: NSColor
            switch next.readiness {
            case .ready, .readyLight, .sessionHit, .sessionHitLight, .weeklyHit, .weeklyHitSoon:
                labelColor = next.readiness.role.nsColor
            default: labelColor = Self.dimText
            }
            draw(String(affix.dropFirst(DesignGlyph.next.count)), labelColor)
            if let glyph = summary.verdictGlyph, full {
                draw(glyph, Self.verdictColor(next.verdict), gapAfter: 0)
            }
        } else {
            // "→—" (nobody) and "⇄" (switching) are short; draw them whenever
            // they fit the block at all.
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.affixFont]
            guard (affix as NSString).size(withAttributes: attributes).width <= available else { return }
            draw(affix, summary.isSwitching ? Self.dimText : DesignRole.blocking.nsColor, gapAfter: 0)
        }
    }

    // MARK: - Composition

    /// `[active tile] [gap] [fleet block]`. The active tile is whatever the
    /// configured style renderer produced for the provider-active account
    /// (or the "no active login" placeholder), drawn dimmed while its last
    /// measurement is stale. Returns the active tile itself when there is no
    /// fleet block (single-account provider).
    func createProviderSummaryTile(
        activeTile: NSImage,
        activeIsStale: Bool,
        fleet: NSImage?
    ) -> NSImage {
        let fleetWidth = fleet?.size.width ?? 0
        let totalWidth = (fleetWidth > 0
            ? activeTile.size.width + FleetBlockGeometry.gap + fleetWidth
            : activeTile.size.width).rounded(.up)
        let height = max(activeTile.size.height, fleet?.size.height ?? 0)

        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }
        opaqueEventShapeBackdrop(in: image)

        activeTile.draw(
            at: NSPoint(x: 0, y: ((height - activeTile.size.height) / 2).rounded()),
            from: .zero, operation: .sourceOver, fraction: activeIsStale ? 0.55 : 1.0
        )
        if let fleet, fleetWidth > 0 {
            fleet.draw(
                at: NSPoint(
                    x: activeTile.size.width + FleetBlockGeometry.gap,
                    y: ((height - fleet.size.height) / 2).rounded()
                ),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
        }
        return image
    }
}
