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
    /// Open, it's just the edge below the top of the screen: for the rim.
    var closed = true

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
        if closed { p.closeSubpath() }
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
        .overlay(alignment: .top) {
            if mode != .hidden, UserDefaults.standard.bool(forKey: Store.rimKey) {
                NotchRim(shape: shape, size: size, canvas: CGSize(width: 640, height: Self.maxHeight(notch: notch)),
                         working: session?.phase.isActive == true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // How much of Claude's task list is done, as a green line growing along the bottom edge
            // (white would melt into a light background below the island).
            if mode != .hidden, let session, session.phase.isActive, session.tasks.current != nil {
                let corner = isOpen ? 20.0 : 10.0
                Capsule()
                    .fill(Color(red: 0.35, green: 0.86, blue: 0.45))
                    .frame(width: max(0, size.width - 2 * (ear + corner)) * session.tasks.fraction, height: NotchRim.width)
                    .padding(.leading, ear + corner)
                    .animation(.easeInOut(duration: 0.5), value: session.tasks.fraction)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            // A big task done: confetti from Clawd's hands over the open island.
            if mode != .hidden, let session, session.cue == .celebrate, Date().timeIntervalSince(session.cueStart) < 4 {
                ConfettiBurst(shape: shape, size: size, canvas: CGSize(width: 640, height: Self.maxHeight(notch: notch)),
                              origin: CGPoint(x: ear + (mode == .compact ? 0 : 6) + 8 + 24, y: (notch.height - 32) / 2 + 14))
                    .id(session.cueStart)
            }
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
        // A little deeper than the camera housing: the rim along the bottom runs inside the edge and
        // must clear the cut-out, where the screen has no pixels, with a sliver of black above it.
        case .compact: body = CGSize(width: notch.width + 2 * wing, height: notch.height + NotchRim.width + 2)
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
                ClawdBadge(session: s, showsHint: mode == .compact && !s.isGreeting)
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
                    if !s.isGreeting { ElapsedLabel(session: s) }
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
                DetailsCard(session: s, others: others) { store.pick($0) }
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
/// says how the turn ended; while it works or waits for you, Clawd typing or waving says enough.
private struct ClawdBadge: View {
    let session: Session
    let showsHint: Bool

    private var hint: String? {
        guard showsHint else { return nil }
        switch session.phase {
        case .done: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .thinking, .tool, .waiting: return nil
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
        if let end = session.turnEnd {  // the turn is over: nothing to tick
            label(end)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in label(context.date) }
        }
    }

    private func label(_ end: Date) -> some View {
        Text(formatElapsed(end.timeIntervalSince(session.turnStart)))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
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
                .lineLimit(1)
                .truncationMode(.middle)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(activity.monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(activity.prose ? .tail : .middle)
            }
        }
    }
}

private struct DetailRow: View {
    let session: Session

    /// The line under the title says why, when Claude said so: its reason for the tool (the file or
    /// pattern then moves up into the title), or a command's description, which reads better than the code.
    /// A question shows itself and its choices.
    private var shown: Activity {
        let a = session.activity
        if !a.options.isEmpty {
            return Activity(symbol: a.symbol, title: a.detail.isEmpty ? a.title : a.detail,
                            detail: a.options.joined(separator: "  ·  "), prose: true)
        }
        if !a.reason.isEmpty {
            let title = a.detail.isEmpty ? a.title : "\(a.title) · \(a.detail)"
            return Activity(symbol: a.symbol, title: title, detail: a.reason, prose: true)
        }
        if a.command, !a.note.isEmpty {
            return Activity(symbol: a.symbol, title: a.title, detail: a.note, prose: true)
        }
        return a
    }

    var body: some View {
        HStack(spacing: 10) {
            let shown = shown
            IconBadge(symbol: shown.symbol, color: session.activity.failed ? .red : phaseColor(session.phase))
            TitleAndDetail(title: shown.title, activity: shown)
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
