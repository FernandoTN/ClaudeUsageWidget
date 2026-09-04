//
//  ThresholdField.swift
//  Claude Usage
//
//  A typed percentage field with commit-on-blur, used for the auto-switch thresholds
//  (Settings › Active & Auto-switch; the legacy Manage Profiles page until 3d).
//

import SwiftUI

// MARK: - Threshold Field

/// Typed percentage threshold: enter a number (80 → 80%), committed on Return
/// or focus loss, clamped to `SharedDataStore.autoSwitchThresholdRange` and
/// saved via the callback. Replaces the previous sliders — a threshold is a
/// deliberate number, not a drag target.
struct ThresholdField: View {
    let title: String
    let description: String
    @Binding var value: Double
    let onSave: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var range: ClosedRange<Double> { SharedDataStore.autoSwitchThresholdRange }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack {
                Text(title)
                    .font(DesignTokens.Typography.body)
                Spacer()
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.body.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                Text("%")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(.secondary)
            }
            Text("\(description) (\(Int(range.lowerBound))–\(Int(range.upperBound)))")
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { text = String(Int(value)) }
        .onChange(of: value) { _, newValue in
            if !focused { text = String(Int(newValue)) }
        }
    }

    private func commit() {
        guard let entered = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(Int(value))  // not a number — revert
            return
        }
        let clamped = min(max(entered, range.lowerBound), range.upperBound)
        value = clamped
        text = String(Int(clamped))
        onSave(clamped)
    }
}
