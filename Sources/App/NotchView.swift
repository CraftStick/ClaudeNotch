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

    static let permissionHeight: CGFloat = 92
    private let ear: CGFloat = 6
    private let wing: CGFloat = 46
    private let detailHeight: CGFloat = 54

    var body: some View {
        let mode = store.mode
        let size = bodySize(mode)
        let shape = NotchShape(topRadius: ear, bottomRadius: mode == .expanded || mode == .permission ? 20 : 10)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if let session = store.focused, mode != .hidden {
                content(session, mode: mode)
                    .padding(.horizontal, ear)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * ear, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(mode == .expanded || mode == .permission ? 0.35 : 0), radius: 10, y: 4)
        .opacity(mode == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mode)
        .animation(.easeInOut(duration: 0.2), value: store.focused?.activity)
    }

    private func bodySize(_ mode: DisplayMode) -> CGSize {
        switch mode {
        case .hidden: return CGSize(width: notch.width, height: notch.height)
        case .compact: return CGSize(width: notch.width + 2 * wing, height: notch.height)
        case .expanded: return CGSize(width: max(notch.width + 2 * wing + 150, 420), height: notch.height + detailHeight)
        case .permission: return CGSize(width: max(notch.width + 2 * wing + 170, 440), height: notch.height + Self.permissionHeight)
        }
    }

    private func content(_ s: Session, mode: DisplayMode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PhaseIcon(session: s)
                    .frame(width: wing)
                Spacer(minLength: notch.width)
                ElapsedLabel(session: s)
                    .frame(width: wing)
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
            default:
                EmptyView()
            }
        }
    }
}

private func phaseColor(_ phase: Phase) -> Color {
    switch phase {
    case .thinking: return claudeOrange
    case .tool: return .white
    case .waiting: return .yellow
    case .done: return .green
    case .stopped: return .gray
    case .failed: return .red
    }
}

private struct PhaseIcon: View {
    let session: Session

    var body: some View {
        Group {
            switch session.phase {
            case .thinking:
                Image(systemName: "sparkle")
                    .symbolEffect(.pulse, options: .repeating)
            case .tool:
                Image(systemName: session.activity.symbol)
                    .contentTransition(.symbolEffect(.replace))
            case .waiting:
                Image(systemName: "hand.raised.fill")
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                Image(systemName: "checkmark")
            case .stopped:
                Image(systemName: "stop.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .foregroundStyle(phaseColor(session.phase))
        .font(.system(size: 13, weight: .semibold))
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

private struct IconBadge: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(symbol: "hand.raised.fill", color: .yellow)
                TitleAndDetail(title: prompt.question, activity: prompt.activity)
                Spacer(minLength: 8)
                if waiting > 0 {
                    Text("ещё \(waiting)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            HStack(spacing: 8) {
                Button("Ответить в приложении") { answer(.askInApp) }
                    .buttonStyle(NotchButtonStyle(kind: .plain))
                Spacer(minLength: 8)
                Button("Запретить") { answer(.deny) }
                    .buttonStyle(NotchButtonStyle(kind: .secondary))
                Button("Разрешить") { answer(.allow) }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct NotchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .plain ? .regular : .semibold))
            .foregroundStyle(kind == .primary ? Color.black : Color.white.opacity(kind == .plain ? 0.5 : 0.9))
            .padding(.horizontal, kind == .plain ? 2 : 14)
            .frame(height: 26)
            .background(Capsule().fill(kind == .primary ? Color.white : Color.white.opacity(kind == .secondary ? 0.14 : 0)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
