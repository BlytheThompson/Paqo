import PaqoCore
import UIKit
import SwiftUI

/// A number with a small label underneath ("24:31" / "TIME").
struct StatBlock: View {
    let value: String
    var unit: String? = nil
    let label: String
    var size: CGFloat = 40
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.number(size))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(label.uppercased())
                .font(Theme.label)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Rounded dark card.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Theme.label)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 8)
    }
}

/// "● Sprint 4 · 0:42"
struct SegmentChip: View {
    let kind: SegmentKind?
    let number: Int
    let duration: TimeInterval
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var color: Color {
        if isPaused { return Theme.textSecondary }
        return kind == .sprint ? Theme.accent : Theme.walk
    }

    private var text: String {
        if isPaused { return "Paused" }
        guard let kind else { return "Getting GPS…" }
        return "\(kind.displayName) \(number) · \(Format.duration(duration))"
    }
}

/// Signal bars for the GPS fix quality.
struct GPSIndicator: View {
    let accuracy: Double?

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < bars ? Theme.accent : Theme.textSecondary.opacity(0.3))
                        .frame(width: 5, height: CGFloat(6 + i * 4))
                }
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var bars: Int {
        guard let accuracy, accuracy >= 0 else { return 0 }
        if accuracy <= 6 { return 3 }
        if accuracy <= 15 { return 2 }
        if accuracy <= 30 { return 1 }
        return 0
    }

    private var label: String {
        switch bars {
        case 3: return "GPS strong"
        case 2: return "GPS good"
        case 1: return "GPS weak"
        default: return accuracy == nil ? "GPS off" : "Finding GPS…"
        }
    }
}

extension RoutePiece {
    var color: Color { kind == .sprint ? Theme.accent : Theme.walk }
}

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet (Save to Files, AirDrop, Mail…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
