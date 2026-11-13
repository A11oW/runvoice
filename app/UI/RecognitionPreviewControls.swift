import AppKit

final class RecognitionPreviewControls: NSStackView, NSTextFieldDelegate {
    private let enabledCheck = NSButton(checkboxWithTitle: "Предварительное распознавание", target: nil, action: nil)
    private let countField = NSTextField(string: "3")
    private let countStepper = NSStepper()
    private let countLabel = NSTextField(labelWithString: "Количество строк в предварительном распознавании")

    var options: RecognitionPreview {
        get { RecognitionPreview(enabled: enabledCheck.state == .on, lineCount: Int(countField.stringValue) ?? RecognitionPreview.defaultLineCount) }
        set {
            enabledCheck.state = newValue.enabled ? .on : .off
            countField.integerValue = newValue.lineCount
            countStepper.integerValue = newValue.lineCount
            updateEnabledState()
        }
    }

    var isLineCountEnabled: Bool { countField.isEnabled && countStepper.isEnabled }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        enabledCheck.identifier = NSUserInterfaceItemIdentifier("preview-enabled")
        enabledCheck.target = self
        enabledCheck.action = #selector(previewToggled)
        enabledCheck.state = .on
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
        countLabel.font = .systemFont(ofSize: 12)
        let range = NSTextField(labelWithString: "1–10")
        range.textColor = .secondaryLabelColor
        range.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [countLabel, countField, countStepper, range])
        row.spacing = 8
        row.alignment = .centerY
        addArrangedSubview(enabledCheck)
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
        let enabled = enabledCheck.state == .on
        countField.isEnabled = enabled
        countStepper.isEnabled = enabled
        countLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
    }
}
