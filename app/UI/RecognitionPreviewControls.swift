import AppKit

final class RecognitionPreviewControls: NSStackView, NSTextFieldDelegate {
    private let enabledSwitch = NSSwitch()
    private let countField = NSTextField(string: "3")
    private let countStepper = NSStepper()
    private let countLabel = SettingsText.rowSubtitle("Количество строк", width: 220)

    var options: RecognitionPreview {
        get { RecognitionPreview(enabled: enabledSwitch.state == .on, lineCount: Int(countField.stringValue) ?? RecognitionPreview.defaultLineCount) }
        set {
            enabledSwitch.state = newValue.enabled ? .on : .off
            countField.integerValue = newValue.lineCount
            countStepper.integerValue = newValue.lineCount
            updateEnabledState()
        }
    }

    var isLineCountEnabled: Bool { countField.isEnabled && countStepper.isEnabled }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 10

        enabledSwitch.identifier = NSUserInterfaceItemIdentifier("preview-enabled")
        enabledSwitch.target = self
        enabledSwitch.action = #selector(previewToggled)
        enabledSwitch.state = .on
        enabledSwitch.setAccessibilityLabel("Показывать предварительный текст")

        let title = SettingsText.rowTitle("Показывать предварительный текст")
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, enabledSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        countField.identifier = NSUserInterfaceItemIdentifier("preview-lines")
        countField.setAccessibilityLabel(countLabel.stringValue)
        countField.delegate = self
        countField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 10
        countField.formatter = formatter
        countStepper.identifier = NSUserInterfaceItemIdentifier("preview-lines-stepper")
        countStepper.minValue = 1
        countStepper.maxValue = 10
        countStepper.increment = 1
        countStepper.integerValue = RecognitionPreview.defaultLineCount
        countStepper.target = self
        countStepper.action = #selector(stepCount)
        let range = NSTextField(labelWithString: "1–10")
        range.textColor = .secondaryLabelColor
        range.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [countLabel, countField, countStepper, range, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.arrangedSubviews.last?.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        addArrangedSubview(header)
        addArrangedSubview(row)
        updateEnabledState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func commit() {
        let value = options.lineCount
        countField.integerValue = value
        countStepper.integerValue = value
    }

    func controlTextDidEndEditing(_ notification: Notification) { commit() }
    @objc private func previewToggled() { updateEnabledState() }
    @objc private func stepCount() { countField.integerValue = countStepper.integerValue }

    private func updateEnabledState() {
        let enabled = enabledSwitch.state == .on
        countField.isEnabled = enabled
        countStepper.isEnabled = enabled
        countLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
    }
}
