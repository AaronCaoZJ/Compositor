import SwiftUI

/// Camera Raw's RAW section, above Light, for a layer still as its RAW file developed it: the develop's own controls,
/// which develop the file again (`EditorSession.updateCameraRawDevelop`). Exposure and white balance set here work on
/// what the camera recorded, where highlights and color still have their latitude; the sections below it work on the
/// developed pixels, as they do for any layer.
struct CameraRawDevelopControls: View {
    @Bindable var session: EditorSession
    @State private var expanded = true

    private var develop: RawDevelopSettings { session.filterEdit?.rawSettings ?? RawDevelopSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 12)
                        Text("RAW").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("RAW")
                .help("Develops the RAW file again: exposure and white balance from what the camera recorded, before the adjustments below.")
                Spacer(minLength: 0)
                if !develop.isAsShot {
                    Button { session.updateCameraRawDevelop { $0.reset() } } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset RAW to the camera's own settings")
                    .accessibilityLabel("Reset RAW")
                }
            }
            if expanded {
                slider("Exposure", \.exposure, range: -3...3, step: 0.01, decimals: 2, reset: 0,
                       help: "Stops of exposure, from what the camera recorded. Turned down, it brings back highlights the developed layer has lost.")
                slider("Temperature", \.temperature, range: 2000...12000, step: 10, decimals: 0, track: .temperature,
                       reset: develop.asShotTemperature, help: "White balance in Kelvin, starting from the camera's own reading.")
                slider("Tint", \.tint, range: -150...150, step: 1, decimals: 0, track: .tint,
                       reset: develop.asShotTint, help: "Green to magenta, starting from the camera's own reading.")
                slider("Boost", \.boost, range: 0...1, step: 0.01, decimals: 2, reset: 1,
                       help: "The engine's tone curve: 1 is its full contrast, 0 leaves the picture flat, with the most room in its highlights.")
                if develop.supportsNoiseReduction {
                    slider("Noise Reduction", \.noiseReduction, range: 0...1, step: 0.01, decimals: 2,
                           reset: develop.asShotNoiseReduction, help: "Smooths grain as the file is developed, at the cost of fine detail.")
                }
                if develop.supportsLensCorrection || develop.supportsHighlightRecovery {
                    HStack(spacing: 16) {
                        if develop.supportsLensCorrection {
                            Toggle("Lens Correction", isOn: Binding(get: { develop.lensCorrection },
                                                                    set: { on in session.updateCameraRawDevelop { $0.lensCorrection = on } }))
                                .help("Removes the lens's distortion and vignetting, from the profile in the file")
                        }
                        if develop.supportsHighlightRecovery {
                            Toggle("Highlight Recovery", isOn: Binding(get: { develop.highlightRecovery },
                                                                       set: { on in session.updateCameraRawDevelop { $0.highlightRecovery = on } }))
                                .help("Brings back detail in bright areas the camera partly clipped")
                        }
                    }
                }
            }
        }
        .disabled(session.filterEdit?.committing == true)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<RawDevelopSettings, Float>, range: ClosedRange<Double>, step: Double,
                        decimals: Int, track: CameraRawSliderTrack = .plain, reset: Float, help: String) -> some View {
        let value = Double(develop[keyPath: key])
        return HStack(spacing: 10) {
            Text(title)
                .frame(minWidth: CameraRawControls.labelWidth, alignment: .leading)
                .help(help)
                .onTapGesture(count: 2) { set(key, Double(reset), in: range) }
            CameraRawSlider(value: value, range: range, track: track, help: help, step: step,
                            onChange: { new in set(key, (new / step).rounded() * step, in: range) },
                            onReset: { set(key, Double(reset), in: range) })
            TextField(title, value: Binding(get: { value }, set: { set(key, $0, in: range) }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .help(help)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func set(_ key: WritableKeyPath<RawDevelopSettings, Float>, _ value: Double, in range: ClosedRange<Double>) {
        let clamped = Float(min(range.upperBound, max(range.lowerBound, value)))
        session.updateCameraRawDevelop { $0[keyPath: key] = clamped }
    }
}
