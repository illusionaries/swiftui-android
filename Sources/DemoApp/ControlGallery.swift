// ControlGallery.swift — the second demo app: SwiftUI's controls, their variants and modifiers.
//
// Everything here is Apple's own API: the gallery exists to exercise what the port implements and
// to make the gaps visible. It ships as its own app (`scripts/gallery.sh`, a separate APK with its
// own application id) so it never competes with the Atlas demo for the launcher.
//
// The header reads live state back out of the controls, so a screenshot after a tap or a drag
// proves the interaction changed the model and not just the pixels.
import Foundation
import SwiftUI

struct ControlGallery: View {
    @State private var volume: Double = 0.4
    @State private var count = 3
    @State private var mode = 1
    @State private var size = "Medium"
    @State private var name = ""
    @State private var notes = ""
    @State private var enabled = true
    @State private var sharp = false
    @State private var progress: Double = 0.65

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                section("Buttons") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button("Primary") {}
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue))

                            Button("Tinted") {}
                                .foregroundColor(.blue)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.14)))

                            Button("Disabled") {}
                                .disabled(true)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.18)))
                        }

                        Text("buttonStyle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Prominent") {}
                                .font(.system(size: 14, weight: .medium))
                                .buttonStyle(.borderedProminent)
                            Button("Bordered") {}
                                .font(.system(size: 14, weight: .medium))
                                .buttonStyle(.bordered)
                            Button("Plain") {}
                                .font(.system(size: 14))
                                .buttonStyle(.plain)
                        }

                        // The action-and-label form, with a composed label.
                        Button {
                            volume = 0.5
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Reset volume")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green))
                        }
                    }
                }

                section("Toggles") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enabled", isOn: $enabled)
                        Toggle("Sharp corners", isOn: $sharp)
                            .font(.system(size: 14))
                        // `.labelsHidden()` drops the label and keeps the switch: the same control,
                        // a different modifier.
                        Toggle("Hidden label", isOn: $sharp)
                            .labelsHidden()
                        // `.toggleStyle(.button)`: the state shows through the fill instead of a switch.
                        Toggle(isOn: $enabled) {
                            Text("Button style")
                                .font(.system(size: 14))
                        }
                        .toggleStyle(.button)
                    }
                }

                section("Sliders") {
                    VStack(alignment: .leading, spacing: 14) {
                        labelled("Volume", value: "\(Int(volume * 100))%") {
                            Slider(value: $volume)
                        }
                        // Bounded and stepped: the knob snaps to five-percent steps.
                        labelled("Stepped", value: "\(Int(volume * 100))%") {
                            HStack(spacing: 10) {
                                Text("0")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Slider(value: $volume, in: 0 ... 1, step: 0.05)
                                Text("1")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                section("Stepper") {
                    HStack(spacing: 12) {
                        Stepper(value: $count, in: 0 ... 10) {
                            Text("Count")
                                .font(.system(size: 15))
                        }
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }

                section("Picker") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Int selection values.
                        Picker("Mode", selection: $mode) {
                            Text("One").tag(0)
                            Text("Two").tag(1)
                            Text("Three").tag(2)
                        }
                        // String selection values: the same control with a different tag type.
                        Picker("Size", selection: $size) {
                            Text("Small").tag("Small")
                            Text("Medium").tag("Medium")
                            Text("Large").tag("Large")
                        }
                        // `.pickerStyle(.inline)`: one row per option, check mark on the selection.
                        Picker("Inline", selection: $size) {
                            Text("Small").tag("Small")
                            Text("Medium").tag("Medium")
                            Text("Large").tag("Large")
                        }
                        .pickerStyle(.inline)
                    }
                }

                section("Text field") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Empty at rest, so the placeholder form is visible.
                        TextField("Your name", text: $name)
                            .font(.system(size: 15))
                        TextField("Notes", text: $notes)
                            .font(.system(size: 15))
                        // `.textFieldStyle(.plain)`: no plate, no outline.
                        TextField("Plain style", text: $notes)
                            .font(.system(size: 15))
                            .textFieldStyle(.plain)
                    }
                }

                section("Progress") {
                    VStack(alignment: .leading, spacing: 14) {
                        ProgressView(value: progress)
                        // The variant with a label and a current-value label.
                        ProgressView(value: progress) {
                            Text("Downloading")
                                .font(.system(size: 13))
                        } currentValueLabel: {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                }

                section("Label, link, divider") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Storage", systemImage: "bookmark")
                            .font(.system(size: 15))
                        Label("Favourites", systemImage: "star.fill")
                            .font(.system(size: 15))
                        // Icon only: `.labelsHidden()` on a Label keeps the image, drops the title.
                        Label("Hidden title", systemImage: "bookmark.fill")
                            .font(.system(size: 15))
                            .labelsHidden()
                        Link("swift.org", destination: URL(string: "https://swift.org")!)
                            .font(.system(size: 15))
                        Divider()
                        Text("A divider separates these rows")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                section("Modifiers") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("padding, background, corner radius")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            swatch(.indigo, radius: 4)
                            swatch(.teal, radius: 12)
                            swatch(.orange, radius: 22)
                        }
                        Text("shadow and gradient")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white)
                                .frame(width: 56, height: 56)
                                .shadow(color: .black, radius: 8, x: 0, y: 4)
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.indigo, .pink],
                                                     startPoint: UnitPoint(x: 0, y: 0),
                                                     endPoint: UnitPoint(x: 1, y: 1)))
                                .frame(width: 56, height: 56)
                            Capsule()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Text("clip")
                                        .font(.system(size: 11))
                                        .foregroundColor(.blue)
                                )
                        }
                    }
                }
                #if PORT_UI_DEBUG
                // At the end of the content on purpose: the header scrolls away, so the numbers a
                // scroll bug needs are only readable when they are down here too.
                Text(PortDiagnostics.scrollModel ?? "scroll=-")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                #endif
            }
            .padding(20)
        }
    }

    // MARK: - Pieces

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Control Gallery")
                .font(.system(size: 30, weight: .bold))
            Text("Apple's controls, rendered by the port")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            // Live state, so a screenshot proves the controls drive the model.
            Text("\(Int(volume * 100))% · n=\(count) · mode=\(mode) · \(size) · \"\(name)\" · on=\(enabled) · focus=\(PortTextInput.isEditing ? "yes" : "no")")
                .font(.system(size: 11))
                .foregroundColor(.blue)
            #if PORT_UI_DEBUG
            Text(tapDebugLine)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            #endif
        }
    }

    /// Debug read-out for the screenshot: the last tap the scene saw and the node path under it.
    /// Built only in a `PORT_UI_DEBUG` build; the shipped gallery shows just the live state.
    var tapDebugLine: String {
        let tap = PortDiagnostics.lastTap
            .map { "tap=(\(Int($0.x)),\(Int($0.y)))" } ?? "tap=-"
        let path = PortDiagnostics.lastTapPath
        let nodes = path.isEmpty ? "node=-" : "n=\(path.count) " + path.suffix(3).joined(separator: " | ")
        return tap + " " + nodes + " " + (PortDiagnostics.scrollModel ?? "scroll=-")
    }

    func labelled<Content: View>(_ title: String, value: String,
                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
    }

    func swatch(_ color: Color, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(color)
            .frame(width: 56, height: 56)
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
    }
}
