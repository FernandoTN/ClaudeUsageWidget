//
//  ActivePill.swift
//  Claude Usage
//
//  The one mark for "Active for <provider>" (docs/specs/ux-revamp.md §1 R1,
//  round-3 R2): a small capsule in the active colour reading "Active", with the
//  provider in its tooltip. Used by the Accounts roster, Settings › Active &
//  Auto-switch and the telemetry window's sidebar — one mark for one concept,
//  never the provider's word under a provider header, never a letter code.
//

import SwiftUI

struct ActivePill: View {
    let provider: Profile.ProviderKind

    var body: some View {
        Text(ActiveVocabulary.activeWord)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(DesignRole.active.color))
            .help(ActiveVocabulary.activeFor(provider))
            .accessibilityLabel(ActiveVocabulary.activeFor(provider))
    }
}
