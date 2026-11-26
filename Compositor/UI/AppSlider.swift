import AppKit
import Combine
import SwiftUI

/// The slider under the pointer takes ← and →, as Lightroom's sliders do: a step, a larger one with Shift, the
/// smallest there is with Option. It needs no click and no focus, and works over a panel as over the document's
/// window. Where text is being typed the arrows stay with its insertion point, except in an edit panel, whose
/// fields are the numbers beside its sliders: there the pointer says which the arrows are for.
final class SliderKeys {
    static let shared = SliderKeys()
    /// Sent to every slider; the one hovered takes it.
    let nudges = PassthroughSubject<(slider: UUID, direction: Int, flags: NSEvent.ModifierFlags), Never>()
    private var hovered: (slider: UUID, window: Int)?
    private var monitor: Any?

    /// The window under the pointer: the slider's own, unless something has since opened over it.
    private static var windowUnderPointer: Int { NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) }

    func enter(_ slider: UUID) {
        hovered = (slider, Self.windowUnderPointer)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let hovered = self.hovered, event.keyCode == 123 || event.keyCode == 124,
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  hovered.window == Self.windowUnderPointer else { return event }
            if let window = event.window, window.firstResponder is NSText {
                guard FloatingPanelController.owns(window) else { return event }
                // The field ends its edit first, keeping what was typed: left mid-edit, it would write its old
                // number back over the slider's when it is next left.
                window.makeFirstResponder(nil)
            }
            self.nudges.send((hovered.slider, event.keyCode == 124 ? 1 : -1, event.modifierFlags))
            return nil
        }
    }

    func leave(_ slider: UUID) {
        if hovered?.slider == slider { hovered = nil }
    }
}

/// The app's slider: a slim track and a narrow upright knob that marks the value like a fader, rather than the
/// system's wide glass knob, which hid a color track's colors under it. A press on the track puts the knob under the
/// pointer and drags from there; a press on the knob drags it from where it is.
struct AppSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value?
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(value: Binding<Value>, in range: ClosedRange<Value>, step: Value? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        SliderTrackView(fraction: SliderGeometry.fraction(of: Double(value), in: Double(range.lowerBound)...Double(range.upperBound)),
                        colors: nil,
                        onBegin: { onEditingChanged(true) },
                        onChange: { fraction in value = snapped(fraction) },
                        onEnd: { onEditingChanged(false) },
                        onReset: nil,
                        unit: step.map { Double($0) / Double(range.upperBound - range.lowerBound) })
            .accessibilityValue(Text(String(format: "%.0f", Double(value))))
            .accessibilityAdjustableAction { direction in
                let nudge = step ?? (range.upperBound - range.lowerBound) / 20
                switch direction {
                case .increment: value = min(range.upperBound, value + nudge)
                case .decrement: value = max(range.lowerBound, value - nudge)
                @unknown default: break
                }
            }
    }

    private func snapped(_ fraction: Double) -> Value {
        var result = range.lowerBound + Value(fraction) * (range.upperBound - range.lowerBound)
        if let step, step > 0 { result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step }
        return min(range.upperBound, max(range.lowerBound, result))
    }
}

/// Where along the track a value sits, and which value a point on the track stands for.
enum SliderGeometry {
    static let knobSize = CGSize(width: 10, height: 18)
    /// The track's thickness: a color track is a little thicker, so its colors read.
    static let plainTrack: CGFloat = 3
    static let colorTrack: CGFloat = 4

    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound, value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    /// The fraction whose knob is centered at `x` on a track `width` wide: the knob's center travels from half a knob
    /// in from one end to half a knob in from the other.
    static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        let travel = width - knobSize.width
        guard travel > 0 else { return 0 }
        return Double(min(1, max(0, (x - knobSize.width / 2) / travel)))
    }

    /// How far the fill reaches: to the knob's center, as macOS's own sliders do, except over the last few points at
    /// each end, where it ramps quickly to empty and to full, so the glass knob shows none at the minimum and all at
    /// the maximum.
    static func fillWidth(fraction: Double, width: CGFloat) -> CGFloat {
        let half = knobSize.width / 2, travel = max(0, width - knobSize.width)
        let position = CGFloat(fraction) * travel, ramp = min(6, travel / 2)
        guard ramp > 0 else { return CGFloat(fraction) * width }
        if position < ramp { return position / ramp * (ramp + half) }
        let remaining = travel - position
        if remaining < ramp { return width - remaining / ramp * (ramp + half) }
        return position + half
    }

    static func knobCenter(fraction: Double, width: CGFloat) -> CGFloat {
        knobSize.width / 2 + CGFloat(fraction) * max(0, width - knobSize.width)
    }
}

/// The drawn slider and its pointer handling, shared by `AppSlider` and Camera Raw's sliders. `colors`, when set,
/// paint the whole track as a gradient in place of the filled bar.
struct SliderTrackView: View {
    let fraction: Double
    let colors: [Color]?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    /// A double-click on the knob; nil when the slider has no default to go back to.
    let onReset: (() -> Void)?
    /// One step of the value's own grid, as a fraction of the track, which the arrow keys move in; nil for a value
    /// without one.
    var unit: Double? = nil
    @Environment(\.isEnabled) private var isEnabled
    @State private var grab: CGFloat?
    @State private var resetting = false
    @State private var lastKnobPress: Date?
    @State private var keysID = UUID()
    @State private var hovered = false
    /// The last arrow-key press, when it left the value where it was.
    @State private var stalled: (from: Double, asked: Double)?

    /// ← or → with the pointer over the slider: about a hundredth of the track, a twentieth with Shift, and the
    /// value's smallest step with Option, each a whole number of those steps so the value stays on its grid.
    private func nudge(_ direction: Int, flags: NSEvent.ModifierFlags) {
        guard isEnabled, grab == nil else { return }
        let smallest = unit ?? 0.005
        let steps = max(1, (0.01 / smallest).rounded())
        let count = flags.contains(.option) ? 1 : flags.contains(.shift) ? max(steps * 2, (0.05 / smallest).rounded()) : steps
        let move = Double(direction) * count * smallest
        // A value its owner rounds to a grid coarser than the step stays put (no `unit` said so): the next press
        // carries on from what the last asked for, and gets there.
        let pushing = stalled.map { $0.from == fraction && ($0.asked - fraction) * move > 0 } ?? false
        let target = min(1, max(0, (pushing ? stalled?.asked ?? fraction : fraction) + move))
        stalled = (fraction, target)
        onBegin()
        onChange(target)
        onEnd()
    }

    /// Solid while it rests; held, it turns to Liquid Glass and grows a little, as the system's knob does, so the
    /// track shows through it. A soft shadow, not an outline, keeps it apart from a light track. Before macOS 26 there
    /// is no Liquid Glass, and the system's knob stays solid and its size while held, so this one does too.
    private var knob: some View {
        let shape = RoundedRectangle(cornerRadius: SliderGeometry.knobSize.width / 2, style: .continuous)
        return Group {
            if #available(macOS 26.0, *), grab != nil {
                shape.fill(.clear).glassEffect(.clear, in: shape)
            } else {
                shape.fill(Color(white: 0.92)).shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            }
        }
        // Ringed under the pointer: this is the slider the arrow keys move.
        .overlay { if hovered, grab == nil { shape.strokeBorder(Color.accentColor, lineWidth: 1.5) } }
        .frame(width: SliderGeometry.knobSize.width, height: SliderGeometry.knobSize.height)
        .scaleEffect(grab != nil && Self.knobGrows ? 1.25 : 1)
        .animation(.easeOut(duration: 0.15), value: grab != nil)
    }

    private static var knobGrows: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let center = SliderGeometry.knobCenter(fraction: fraction, width: width)
            let thickness = colors == nil ? SliderGeometry.plainTrack : SliderGeometry.colorTrack
            ZStack(alignment: .leading) {
                if let colors, colors.count >= 2 {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(height: thickness)
                } else {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: thickness)
                    Capsule().fill(Color.accentColor).frame(width: SliderGeometry.fillWidth(fraction: fraction, width: width), height: thickness)
                }
                knob
                    .offset(x: center - SliderGeometry.knobSize.width / 2)
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                if grab == nil {
                    // On the knob, it drags from where it is; on the track, it jumps under the pointer first.
                    let onKnob = abs(drag.startLocation.x - center) <= SliderGeometry.knobSize.width / 2 + 3
                    if onKnob, let onReset, let last = lastKnobPress, Date().timeIntervalSince(last) < NSEvent.doubleClickInterval {
                        lastKnobPress = nil
                        resetting = true
                        grab = 0
                        onReset()
                        return
                    }
                    lastKnobPress = onKnob ? Date() : nil
                    grab = onKnob ? drag.startLocation.x - center : 0
                    onBegin()
                }
                guard !resetting, let grab else { return }
                onChange(SliderGeometry.fraction(atX: drag.location.x - grab, width: width))
            }.onEnded { _ in
                if !resetting { onEnd() }
                resetting = false
                grab = nil
            })
        }
        .frame(minWidth: 40, maxWidth: .infinity)
        .frame(height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .onHover { inside in
            hovered = inside && isEnabled
            if hovered { SliderKeys.shared.enter(keysID) } else { SliderKeys.shared.leave(keysID) }
        }
        .onDisappear { SliderKeys.shared.leave(keysID) }
        .onReceive(SliderKeys.shared.nudges) { nudge in
            if nudge.slider == keysID { self.nudge(nudge.direction, flags: nudge.flags) }
        }
    }
}
