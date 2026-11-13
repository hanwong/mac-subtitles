import SwiftUI
import Translation

/// The settings window. It also hosts the translation session, so it must stay open while running.
struct ControlView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker("오디오 언어", selection: $model.sourceLocaleID) {
                ForEach(model.sourceOptions) { Text($0.name).tag($0.id) }
            }
            .disabled(model.isRunning || model.isStarting)

            Picker("자막 언어", selection: $model.targetLanguageID) {
                ForEach(model.targetOptions) { Text($0.name).tag($0.id) }
            }

            LabeledContent("글자 크기") {
                Slider(value: $model.fontSize, in: 16...72, step: 2)
                Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }

            Toggle("원문도 함께 표시", isOn: $model.showOriginal)

            Section {
                Button(model.isRunning ? "자막 중지" : "자막 시작") { model.toggle() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isStarting)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRunning {
                    LabeledContent("오디오 입력", value: audioInputDescription)
                    if !model.recognitionError.isEmpty {
                        LabeledContent("인식 오류") {
                            Text(model.recognitionError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("인식된 음성") {
                        Text(model.heardText.isEmpty ? "(아직 없음)" : model.heardText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .translationTask(model.translationConfiguration) { session in
            await model.runTranslation(with: session)
        }
    }
}

extension ControlView {
    /// Tells apart "no audio is reaching the app" from "audio arrives but nothing is recognized".
    fileprivate var audioInputDescription: String {
        guard let level = model.audioLevel else { return "수신 안 됨" }
        return level < 0.001 ? "무음" : "소리 감지됨 (\(Int((level * 100).rounded()))%)"
    }
}

/// Content of the click-through overlay pinned to the bottom of the screen.
struct SubtitleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            if !model.translatedText.isEmpty {
                VStack(spacing: 4) {
                    if model.showOriginal, model.originalText != model.translatedText {
                        line(model.originalText)
                            .font(.system(size: model.fontSize * 0.6, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    line(model.translatedText)
                        .font(.system(size: model.fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A whole sentence at a time: long ones shrink a little before they are cut off.
    private func line(_ text: String) -> some View {
        Text(text)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
