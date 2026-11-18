import CodexBarCore
import SwiftUI

struct CodexResetCreditPresentationItem: Equatable {
    let expiryText: String
    let compactExpiryText: String
    let isExpiringSoon: Bool

    init(expiryText: String, compactExpiryText: String, isExpiringSoon: Bool = false) {
        self.expiryText = expiryText
        self.compactExpiryText = compactExpiryText
        self.isExpiringSoon = isExpiringSoon
    }
}

struct CodexResetCreditsPresentation: Equatable {
    let text: String
    let items: [CodexResetCreditPresentationItem]

    var expirySummaryText: String {
        let visibleItems = self.items.prefix(4).map(\.compactExpiryText)
        let hiddenCount = self.items.count - visibleItems.count
        let suffix = hiddenCount > 0 ? ["+\(hiddenCount)"] : []
        return (visibleItems + suffix).joined(separator: " · ")
    }

    var helpText: String {
        self.items.enumerated().map { index, item in
            "\(index + 1). \(item.expiryText)"
        }.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        [L("Limit Reset Credits"), self.text, self.helpText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func make(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> CodexResetCreditsPresentation?
    {
        let inventory = snapshot.availableInventory(at: now)
        guard !inventory.credits.isEmpty else { return nil }
        let items = inventory.credits.map { credit in
            Self.presentationItem(for: credit, resetStyle: resetStyle, now: now)
        }
        return CodexResetCreditsPresentation(
            text: Self.availableText(count: inventory.count),
            items: items)
    }

    private static func availableText(count: Int) -> String {
        count == 1 ? L("1 available") : String(format: L("%d available"), count)
    }

    private static func presentationItem(
        for credit: CodexRateLimitResetCredit,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> CodexResetCreditPresentationItem
    {
        guard let expiresAt = credit.expiresAt else {
            return CodexResetCreditPresentationItem(expiryText: L("No expiry"), compactExpiryText: L("No expiry"))
        }
        let formattedTime = Self.formattedTime(expiresAt, resetStyle: resetStyle, now: now)
        let compactExpiryText = resetStyle == .countdown && formattedTime.hasPrefix("in ")
            ? String(formattedTime.dropFirst(3))
            : formattedTime
        return CodexResetCreditPresentationItem(
            expiryText: String(format: L("Expires %@"), formattedTime),
            compactExpiryText: compactExpiryText,
            isExpiringSoon: expiresAt.timeIntervalSince(now) <= 3 * 86400)
    }

    private static func formattedTime(
        _ expiresAt: Date,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> String
    {
        switch resetStyle {
        case .absolute:
            return UsageFormatter.resetDescription(from: expiresAt, now: now)
        case .countdown:
            let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
            return countdown == "now" ? L("now") : countdown
        }
    }
}

struct CodexResetCreditsContent: View {
    let presentation: CodexResetCreditsPresentation
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Limit Reset Credits"))
                    .font(ConsoleDesign.text(11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(self.presentation.text)
                    .font(ConsoleDesign.mono(11, weight: .semibold))
                    .foregroundStyle(
                        self.isHighlighted ? MenuHighlightStyle.primary(true) : ConsoleDesign.accentForeground)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                ForEach(Array(self.presentation.items.prefix(4).enumerated()), id: \.offset) { _, item in
                    Text(item.compactExpiryText)
                        .font(ConsoleDesign.mono(9.5, weight: .medium))
                        .foregroundStyle(
                            item.isExpiringSoon ? ConsoleDesign.cautionForeground : ConsoleDesign.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                                .fill(ConsoleDesign.surface2))
                        .overlay {
                            RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                                .stroke(
                                    item.isExpiringSoon ? ConsoleDesign.caution : ConsoleDesign.border,
                                    lineWidth: 1)
                        }
                }
                if self.presentation.items.count > 4 {
                    Text("+\(self.presentation.items.count - 4)")
                        .font(ConsoleDesign.mono(9.5))
                        .foregroundStyle(ConsoleDesign.tertiaryForeground)
                }
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(self.presentation.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.presentation.accessibilityLabel)
    }
}

extension UsageMenuCardView.Model {
    static func codexResetCredits(input: Input) -> CodexResetCreditsPresentation? {
        guard input.provider == .codex,
              let resetCredits = input.snapshot?.codexResetCredits
        else {
            return nil
        }
        return CodexResetCreditsPresentation.make(
            snapshot: resetCredits,
            resetStyle: input.resetTimeDisplayStyle,
            now: input.now)
    }
}
