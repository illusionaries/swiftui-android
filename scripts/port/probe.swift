// probe.swift — the fidelity gate for the port.
//
// This is ordinary SwiftUI application code, written exactly as it would be for iOS.
// It is compiled for aarch64 Android against Apple's *real* SwiftUI module interface
// (retargeted, see retarget_interface.py). If this typechecks, the port exposes the
// genuine SwiftUI API surface, not an invented one.
import SwiftUI

struct ProbeRow: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Text("A").font(.headline).foregroundColor(.blue))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct ProbeApp: View {
    @State private var count = 0
    @State private var items = ["Alpha", "Beta", "Gamma"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SwiftUI")
                        .font(.largeTitle).bold()
                        .padding(.bottom, 4)
                    Text("Running on Android")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 16)

                    ForEach(items, id: \.self) { item in
                        ProbeRow(title: item, subtitle: "subtitle for \(item)")
                        Divider()
                    }

                    Button {
                        count += 1
                    } label: {
                        Text("Tapped \(count) times")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .padding(.top, 24)

                    Text("counter: \(count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Port")
        }
        .preferredColorScheme(.dark)
    }
}
