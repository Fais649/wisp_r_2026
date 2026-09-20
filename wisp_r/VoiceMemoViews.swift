import SwiftUI

// MARK: - Waveform

/// The recorded levels as bars, brightened up to the playback position.
struct WaveformView: View {
    let samples: [Float]
    var progress: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let bars = samples.isEmpty ? [Float](repeating: 0.12, count: 32) : samples
            let barWidth = max((proxy.size.width - CGFloat(bars.count - 1) * 2) / CGFloat(bars.count), 1)

            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.enumerated(), id: \.offset) { index, sample in
                    Capsule()
                        .fill(
                            Double(index) / Double(bars.count) <= progress
                                ? Color.wisprInk
                                : Color.wisprInk.opacity(0.28)
                        )
                        .frame(
                            width: barWidth,
                            height: max(CGFloat(sample) * proxy.size.height, 2)
                        )
                }
            }
            .frame(height: proxy.size.height, alignment: .center)
        }
    }
}

// MARK: - Voice memo

/// A voice memo with its playback controls and, once transcribed, a transcript
/// that can be collapsed.
///
/// Floats inside a day view card or the editor's pinned area as a rounded
/// Liquid Glass surface.
struct VoiceMemoView: View {
    let attachment: NoteAttachment
    /// Collapsed shows the first two lines of the transcript.
    @Binding var isTranscriptExpanded: Bool
    let onTranscribe: () -> Void
    var isTranscribing = false
    var transcriptionError: String?

    private let player = VoiceMemoPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls

            if let transcript = attachment.transcript {
                TranscriptView(transcript: transcript, isExpanded: $isTranscriptExpanded)
            } else if let transcriptionError {
                Text(transcriptionError)
                    .font(.wispr(12))
                    .foregroundStyle(Color.wisprInk.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(Color.wisprInk.opacity(0.08)),
            in: .rect(cornerRadius: 18)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(attachment)
            } label: {
                Image(systemName: player.isPlaying(attachment) ? "pause.fill" : "play.fill")
                    .font(.wispr(15))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Color.wisprInk, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying(attachment) ? "Pause memo" : "Play memo")

            WaveformView(samples: attachment.waveform, progress: player.progress(for: attachment))
                .frame(height: 28)
                .frame(maxWidth: .infinity)

            Text(timeLabel)
                .font(.wispr(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.wisprInk.opacity(0.7))

            Button {
                player.reset(attachment)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.wispr(14))
                    .foregroundStyle(Color.wisprInk.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restart memo")

            transcribeButton
        }
    }

    private var timeLabel: String {
        Duration.seconds(player.displayedTime(for: attachment))
            .formatted(.time(pattern: .minuteSecond))
    }

    @ViewBuilder
    private var transcribeButton: some View {
        if isTranscribing {
            ProgressView()
                .controlSize(.small)
                .tint(Color.wisprInk)
        } else if attachment.transcript == nil {
            Button(action: onTranscribe) {
                Image(systemName: "text.viewfinder")
                    .font(.wispr(15))
                    .foregroundStyle(Color.wisprInk.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcribe memo")
        }
    }

}

// MARK: - Transcript

/// A memo's transcript. Short enough to fit in two lines and it is shown as
/// plain text; longer than that and it gains a header to expand and collapse it.
private struct TranscriptView: View {
    let transcript: String
    @Binding var isExpanded: Bool

    private static let font = Font.wispr(14)
    private static let collapsedLineLimit = 2

    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    /// True once the text needs more than the collapsed number of lines. Both
    /// heights are measured off-screen so the answer doesn't change with the
    /// expanded state.
    private var overflowsCollapsedHeight: Bool {
        fullHeight - collapsedHeight > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if overflowsCollapsedHeight {
                disclosure
            }

            Text(transcript)
                .font(Self.font)
                .foregroundStyle(Color.wisprInk.opacity(0.85))
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .background(alignment: .top) { heightProbes }
        }
    }

    private var disclosure: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.wispr(12, weight: .semibold))
                    .foregroundStyle(Color.wisprSecondaryText)

                Image(systemName: "chevron.down")
                    .font(.wispr(10, weight: .semibold))
                    .foregroundStyle(Color.wisprSecondaryText)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Copies of the text laid out at the same width, one unclamped and one
    /// clamped, purely to compare their heights. A background doesn't affect
    /// the layout around it.
    private var heightProbes: some View {
        ZStack(alignment: .top) {
            Text(transcript)
                .font(Self.font)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }

            Text(transcript)
                .font(Self.font)
                .lineLimit(Self.collapsedLineLimit)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedHeight = $0 }
        }
        .hidden()
    }
}

#if DEBUG
#Preview {
    @Previewable @State var expanded = false

    VStack(spacing: 16) {
        VoiceMemoView(
            attachment: NoteAttachment(
                kind: .audio,
                fileName: "memo.m4a",
                displayName: "Voice memo",
                duration: 67,
                waveform: (0..<44).map { index in
                    Float(0.2 + 0.7 * abs(sin(Double(index) / 4)))
                },
                transcript: "Remember to call the bike shop about the wheel, and ask whether they can fit new brake pads before the weekend trip."
            ),
            isTranscriptExpanded: $expanded,
            onTranscribe: {}
        )

        // Short enough for two lines, so no Transcript header.
        VoiceMemoView(
            attachment: NoteAttachment(
                kind: .audio,
                fileName: "memo2.m4a",
                displayName: "Voice memo",
                duration: 8,
                waveform: (0..<44).map { index in
                    Float(0.3 + 0.6 * abs(sin(Double(index) / 3)))
                },
                transcript: "Bring the blue folder."
            ),
            isTranscriptExpanded: .constant(false),
            onTranscribe: {}
        )

        VoiceMemoView(
            attachment: NoteAttachment(
                kind: .audio,
                fileName: "memo3.m4a",
                displayName: "Voice memo",
                duration: 8,
                waveform: (0..<44).map { index in
                    Float(0.2 + 0.7 * abs(cos(Double(index) / 5)))
                }
            ),
            isTranscriptExpanded: .constant(false),
            onTranscribe: {}
        )
    }
    .padding(.vertical)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WisprBackground())
    .preferredColorScheme(.dark)
}
#endif
