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
    nonisolated static func readinessColor(_ readiness: AccountReadiness) -> NSColor {
        switch readiness {
        case .ready: return .systemGreen
        case .low: return .systemOrange
        case .exhausted: return .systemRed
        case .suspected: return .systemPurple
        case .dead: return .systemOrange
        case .excluded, .unknown: return NSColor(calibratedWhite: 0.72, alpha: 1.0)
        }
    }

    /// Colour of the verdict glyph after the affix.
    nonisolated static func verdictColor(_ verdict: NextCandidate.Verdict) -> NSColor {
        switch verdict {
        case .verified: return .systemGreen
        case .unverified: return NSColor(calibratedWhite: 0.72, alpha: 1.0)
        case .dead: return .systemRed
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

        // Provider mark, top-left, beside the top dot row.
        (Self.providerMark(summary.provider) as NSString).draw(
            at: NSPoint(x: 0, y: height - 7),
            withAttributes: [.font: Self.markFont, .foregroundColor: Self.dimText]
        )

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

        drawCandidateRow(summary, at: NSPoint(x: matrixX, y: 0))
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
            case .ready, .low, .exhausted, .suspected:
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
        }
        if overflow > 0 {
            // Two reserved columns left of the matrix — the latest-reset end
            // of the ranking, the least decision-relevant one. `+17` at 6 pt
            // is 11 pt wide; the mark's own column (0..10) stays clear.
            let x = max(originX, leftmostX - CGFloat(FleetBlockGeometry.overflowColumns) * FleetBlockGeometry.dotPitch)
            ("+\(overflow)" as NSString).draw(
                at: NSPoint(x: x, y: top - d - CGFloat(grid.rows - 1) * FleetBlockGeometry.rowPitch - 1.5),
                withAttributes: [.font: Self.markFont, .foregroundColor: Self.dimText]
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
        let cells: [(glyph: String, state: AccountReadiness)] = [
            ("●", .ready), ("◐", .low), ("▲", .exhausted), ("×", .dead),
        ]
        var x = origin.x
        for cell in cells {
            let n = counts[cell.state, default: 0]
            guard n > 0 else { continue }
            let text = "\(cell.glyph)\(n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.countsFont, .foregroundColor: Self.readinessColor(cell.state),
            ]
            text.draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
            x += text.size(withAttributes: attributes).width + 2
        }
    }

    /// Row 3: the active account's digits (tinted by ITS evidence), the
    /// candidate affix (tinted by the candidate's quota evidence) and the
    /// verdict glyph (tinted by the login evidence). Nothing while idle.
    private func drawCandidateRow(_ summary: ProviderSummary, at origin: NSPoint) {
        guard let affix = summary.affix else { return }
        let text = NSMutableAttributedString()
        if let digits = summary.activeDigits, !summary.isSwitching {
            let color: NSColor
            switch summary.activeReadiness {
            case .suspected?: color = .systemPurple
            case .exhausted?: color = StatusBarUIManager.weeklyMaxedLabelColor
            default: color = Self.brightText
            }
            text.append(NSAttributedString(string: "\(digits)", attributes: [
                .font: Self.affixFont, .foregroundColor: color
            ]))
        }
        // Prefix (→ / Q→ / ⇄) in neutral white — a RED Q when the queue head
        // is blocked and this is the ranked fallback; the candidate's name
        // in ITS quota colour (green fresh headroom, orange near a limit,
        // grey stale/unknown); "→—" red: nobody to go to.
        if let next = summary.next, !summary.isSwitching {
            let labelStart = affix.index(affix.endIndex, offsetBy: -min(3, next.label.count))
            let prefix = String(affix[..<labelStart])
            let name = String(affix[labelStart...])
            if next.queueHeadBlocked, prefix.hasPrefix("Q") {
                text.append(NSAttributedString(string: "Q", attributes: [
                    .font: Self.affixFont, .foregroundColor: NSColor.systemRed
                ]))
                text.append(NSAttributedString(string: String(prefix.dropFirst()), attributes: [
                    .font: Self.affixFont, .foregroundColor: Self.brightText
                ]))
            } else {
                text.append(NSAttributedString(string: prefix, attributes: [
                    .font: Self.affixFont, .foregroundColor: Self.brightText
                ]))
            }
            let labelColor: NSColor
            switch next.readiness {
            case .ready: labelColor = .systemGreen
            case .low: labelColor = .systemOrange
            default: labelColor = Self.dimText
            }
            text.append(NSAttributedString(string: name, attributes: [
                .font: Self.affixFont, .foregroundColor: labelColor
            ]))
        } else {
            text.append(NSAttributedString(string: affix, attributes: [
                .font: Self.affixFont,
                .foregroundColor: summary.isSwitching ? Self.dimText : NSColor.systemRed
            ]))
        }
        if let glyph = summary.verdictGlyph, let next = summary.next {
            text.append(NSAttributedString(string: glyph, attributes: [
                .font: Self.affixFont, .foregroundColor: Self.verdictColor(next.verdict)
            ]))
        }
        text.draw(at: origin)
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
