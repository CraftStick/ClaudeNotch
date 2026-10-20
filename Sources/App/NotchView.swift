import AppKit
import SwiftUI

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

struct NotchMetrics {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
            hasNotch = true
        } else {
            // No notch (external display): draw a small "virtual" one in the menu bar.
            width = 150
            height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            hasNotch = false
        }
    }
}

/// Black shape that hangs from the top edge like the real notch:
/// small outward curves at the top, rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, (r.height - t) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var store: Store
    let notch: NotchMetrics

    static let permissionHeight: CGFloat = 104
    private static let ear: CGFloat = 6
    /// Room on each side of the notch: Clawd (36) and his hint icon (~14) on the left must fit,
    /// or the icon slides under the camera.
    private static let wing: CGFloat = 72
    private static let detailHeight: CGFloat = 54
    private var ear: CGFloat { Self.ear }
    private var wing: CGFloat { Self.wing }
    private var detailHeight: CGFloat { Self.detailHeight }

    var body: some View {
        let mode = store.mode
        let session = store.focused
        let others = store.others(than: session?.id)
        let size = Self.size(of: mode, session: session, others: others.count, notch: notch)
        let isOpen = mode == .expanded || mode == .permission || mode == .details
        let shape = NotchShape(topRadius: ear, bottomRadius: isOpen ? 20 : 10)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if let session, mode != .hidden {
                content(session, others: others, mode: mode)
                    .padding(.horizontal, ear)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {  // buttons inside win over this
            if let session { store.focus(session.id) }
        }
        .shadow(color: .black.opacity(isOpen ? 0.35 : 0), radius: 10, y: 4)
        .opacity(mode == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: size)
        .animation(.easeInOut(duration: 0.2), value: store.focused?.activity)
    }

    /// Outer size of the black shape (including the small top curves) for `mode`.
    static func size(of mode: DisplayMode, session: Session?, others: Int = 0, notch: NotchMetrics) -> CGSize {
        let body: CGSize
        switch mode {
        case .hidden: body = CGSize(width: notch.width, height: notch.height)
        case .compact: body = CGSize(width: notch.width + 2 * wing, height: notch.height)
        case .expanded: body = CGSize(width: max(notch.width + 2 * wing + 150, 420), height: notch.height + detailHeight)
        case .permission: body = CGSize(width: max(notch.width + 2 * wing + 190, 470), height: notch.height + permissionHeight)
        case .details:
            body = CGSize(width: max(notch.width + 2 * wing + 190, 470),
                          height: notch.height + (session.map { DetailsLayout.height($0, others: others) } ?? detailHeight))
        }
        return CGSize(width: body.width + 2 * ear, height: body.height)
    }

    /// Tallest the shape can get, for sizing the window.
    static func maxHeight(notch: NotchMetrics) -> CGFloat {
        notch.height + max(permissionHeight, DetailsLayout.maxHeight)
    }

    private func content(_ s: Session, others: [Session], mode: DisplayMode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ClawdBadge(session: s, showsHint: mode == .compact)
                    .padding(.leading, 8)
                    .frame(width: wing, alignment: .leading)
                Spacer(minLength: notch.width)
                HStack(spacing: 5) {
                    let busy = store.working.count
                    if busy > 1 {
                        Text("\(busy)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(claudeOrange))
                            .help(tr("Сессий в работе: \(busy)", "Sessions at work: \(busy)"))
                    }
                    ElapsedLabel(session: s)
                }
                .padding(.trailing, 10)
                .frame(width: wing, alignment: .trailing)
            }
            .padding(.horizontal, mode == .compact ? 0 : 6)
            .frame(height: notch.height)

            switch mode {
            case .expanded:
                DetailRow(session: s)
                    .frame(height: detailHeight, alignment: .top)
            case .permission:
                if let prompt = store.prompt {
                    PermissionCard(prompt: prompt, waiting: store.prompts.count - 1) { store.answer(prompt, $0) }
                        .frame(height: Self.permissionHeight, alignment: .top)
                }
            case .details:
                DetailsCard(session: s, others: others) { store.focus($0) }
                    .frame(height: DetailsLayout.height(s, others: others.count), alignment: .top)
            default:
                EmptyView()
            }
        }
    }
}

func phaseColor(_ phase: Phase) -> Color {
    switch phase {
    case .thinking: return claudeOrange
    case .tool: return .white
    case .waiting: return .yellow
    case .done: return .green
    case .stopped: return .gray
    case .failed: return .red
    }
}

/// Claude itself (Clawd). In the compact notch, where there is no detail row, a small hint
/// says when it waits for you or has stopped; while it works, Clawd typing says enough.
private struct ClawdBadge: View {
    let session: Session
    let showsHint: Bool

    private var hint: String? {
        guard showsHint else { return nil }
        switch session.phase {
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .thinking, .tool: return nil
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ClawdView(session: session)
            if let hint {
                Image(systemName: hint)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(phaseColor(session.phase))
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

private struct ElapsedLabel: View {
    let session: Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = session.turnEnd ?? context.date
            Text(formatElapsed(end.timeIntervalSince(session.turnStart)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct IconBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
    }
}

private struct TitleAndDetail: View {
    let title: String
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(activity.monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct DetailRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: session.activity.symbol, color: phaseColor(session.phase))
            TitleAndDetail(title: session.activity.title, activity: session.activity)
            Spacer(minLength: 8)
            if !session.project.isEmpty {
                Text(session.project)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct PermissionCard: View {
    let prompt: PermissionPrompt
    let waiting: Int
    let answer: (Store.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "hand.raised.fill", color: .yellow)
                TitleAndDetail(title: prompt.question, activity: prompt.activity)
                Spacer(minLength: 8)
                if waiting > 0 {
                    Text(tr("ещё \(waiting)", "+\(waiting) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            HStack(spacing: 8) {
                Button(tr("В приложении", "In app")) { answer(.askInApp) }
                    .buttonStyle(NotchButtonStyle(kind: .plain))
                Spacer(minLength: 6)
                Button { answer(.deny) } label: { ShortcutLabel(title: tr("Запретить", "Deny"), key: "⌃⌥⌘N") }
                    .buttonStyle(NotchButtonStyle(kind: .secondary))
                if prompt.ruleSummary != nil {
                    Button(tr("Всегда", "Always")) { answer(.allowAlways) }
                        .buttonStyle(NotchButtonStyle(kind: .secondary))
                }
                Button { answer(.allow) } label: { ShortcutLabel(title: tr("Разрешить", "Allow"), key: "⌃⌥⌘Y") }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
            }
            Text(prompt.ruleSummary.map { tr("«Всегда» добавит правило ", "“Always” adds the rule ") + $0 } ?? " ")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct ShortcutLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.45)
        }
    }
}

private struct NotchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .plain ? .regular : .semibold))
            .foregroundStyle(kind == .primary ? Color.black : Color.white.opacity(kind == .plain ? 0.5 : 0.9))
            .padding(.horizontal, kind == .plain ? 2 : 11)
            .frame(height: 26)
            .background(Capsule().fill(kind == .primary ? Color.white : Color.white.opacity(kind == .secondary ? 0.14 : 0)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
