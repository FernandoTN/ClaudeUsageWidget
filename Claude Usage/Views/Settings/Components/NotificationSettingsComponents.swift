//
//  NotificationSettingsComponents.swift
//  Claude Usage
//
//  The rows of a NotificationSettings editor (threshold toggles, custom thresholds,
//  sound), shared by Settings › Alerts, the account's Alerts tab and the legacy
//  General page until stage 3d deletes it.
//

import SwiftUI

// MARK: - Threshold Toggle Row

struct ThresholdToggleRow: View {
    let level: String
    let color: Color
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(level)
                .font(DesignTokens.Typography.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .frame(width: 32, alignment: .leading)

            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

// MARK: - Custom Thresholds Editor

struct CustomThresholdsEditor: View {
    @Binding var thresholds: [Int]
    @State private var newThresholdText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            // Existing custom thresholds
            if !thresholds.isEmpty {
                ForEach(thresholds.sorted(), id: \.self) { threshold in
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Circle()
                            .fill(colorForThreshold(threshold))
                            .frame(width: 8, height: 8)

                        Text("\(threshold)%")
                            .font(DesignTokens.Typography.caption)
                            .fontWeight(.medium)

                        Text("notifications.custom_threshold".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: {
                            thresholds.removeAll { $0 == threshold }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add new threshold
            HStack(spacing: DesignTokens.Spacing.small) {
                TextField("notifications.custom_placeholder".localized, text: $newThresholdText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit { addThreshold() }

                Text("%")
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)

                Button("notifications.custom_add".localized) {
                    addThreshold()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newThresholdText.isEmpty)
            }
        }
    }

    private func addThreshold() {
        guard let value = Int(newThresholdText),
              value > 0, value <= 100,
              !thresholds.contains(value),
              value != 75, value != 90, value != 95 else {
            newThresholdText = ""
            return
        }
        thresholds.append(value)
        newThresholdText = ""
    }

    private func colorForThreshold(_ threshold: Int) -> Color {
        switch threshold {
        case 90...: return DesignTokens.Colors.error
        case 70..<90: return DesignTokens.Colors.warning
        case 50..<70: return DesignTokens.Colors.usageMedium
        default: return DesignTokens.Colors.success
        }
    }
}

// MARK: - Notification Sound Picker

struct NotificationSoundPicker: View {
    @Binding var soundName: String

    private static let systemSounds: [(name: String, label: String)] = {
        let soundsDir = "/System/Library/Sounds"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { file in
                let name = (file as NSString).deletingPathExtension
                return (name: name, label: name)
            }
            .sorted { $0.label < $1.label }
    }()

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.iconText) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: DesignTokens.Icons.standard))
                .foregroundColor(DesignTokens.Colors.accent)
                .frame(width: DesignTokens.Spacing.iconFrame)

            Text("notifications.sound".localized)
                .font(DesignTokens.Typography.body)

            Spacer()

            Picker("", selection: $soundName) {
                Text("notifications.sound.default".localized).tag("default")
                Divider()
                ForEach(Self.systemSounds, id: \.name) { sound in
                    Text(sound.label).tag(sound.name)
                }
                Divider()
                Text("notifications.sound.none".localized).tag("none")
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            // Preview button
            Button(action: { previewSound() }) {
                Image(systemName: "play.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("notifications.sound.preview".localized)
        }
    }

    private func previewSound() {
        switch soundName {
        case "none":
            break
        case "default":
            NSSound.beep()
        default:
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            }
        }
    }
}
