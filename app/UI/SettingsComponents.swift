import AppKit

// MARK: - Оформление окна настроек
//
// Набор небольших компонентов для экранов настроек: карточки, строки,
// секции, боковой список и нижняя панель. Все цвета семантические,
// чтобы светлая и тёмная темы получались автоматически.

enum SettingsStyle {
    static let sidebarWidth: CGFloat = 236
    static let contentMaxWidth: CGFloat = 700
    static let pageInset: CGFloat = 24
    static let sectionSpacing: CGFloat = 22
    static let sectionTitleSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 16
    static let rowVerticalInset: CGFloat = 11
    static let controlSpacing: CGFloat = 8

    static var pageBackground: NSColor {
        NSColor(name: "SettingsPageBackground") { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1)
                              : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.992, alpha: 1)
        }
    }

    static var cardBackground: NSColor {
        NSColor(name: "SettingsCardBackground") { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1)
                              : NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)
        }
    }

    static var cardBorder: NSColor {
        NSColor(name: "SettingsCardBorder") { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: 0.09)
                              : NSColor(white: 0, alpha: 0.07)
        }
    }

    static var rowSeparator: NSColor {
        NSColor(name: "SettingsRowSeparator") { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: 0.10)
                              : NSColor(white: 0, alpha: 0.08)
        }
    }

    static var sidebarSelection: NSColor {
        NSColor(name: "SettingsSidebarSelection") { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: 0.17)
                              : NSColor(white: 0, alpha: 0.11)
        }
    }

    static var sidebarHover: NSColor {
        NSColor(name: "SettingsSidebarHover") { appearance in
            NSColor(white: appearance.isDark ? 1 : 0, alpha: 0.05)
        }
    }

    static var footerBackground: NSColor {
        NSColor(name: "SettingsFooterBackground") { appearance in
            appearance.isDark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1)
                              : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.992, alpha: 1)
        }
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Текст

enum SettingsText {
    static func pageTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func pageSubtitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        return field
    }

    static func rowTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func rowSubtitle(_ text: String, width: CGFloat = 430) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func footnote(_ text: String, width: CGFloat = 660, warning: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = warning ? .systemOrange : .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        return field
    }


    static func linkButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.font = .systemFont(ofSize: 12.5)
        return button
    }

    static func destructiveButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = linkButton(title, target: target, action: action)
        button.contentTintColor = .systemRed
        return button
    }

    static func secondaryButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }
}

// MARK: - Карточка

final class SettingsCard: NSStackView {
    private(set) var rowViews: [NSView] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        wantsLayer = true
        layer?.cornerRadius = SettingsStyle.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func addRow(_ row: NSView, separated: Bool = true) {
        if separated, !rowViews.isEmpty {
            let separator = SettingsSeparatorView()
            addArrangedFullWidth(separator)
        }
        addArrangedFullWidth(row)
        rowViews.append(row)
    }

    func removeAllRows() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews.removeAll()
    }

    private func applyColors() {
        layer?.backgroundColor = SettingsStyle.cardBackground.cgColor
        layer?.borderColor = SettingsStyle.cardBorder.cgColor
    }
}

final class SettingsSeparatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        layer?.backgroundColor = SettingsStyle.rowSeparator.cgColor
    }
}

/// Строка карточки: заголовок, пояснение и контрол справа.
final class SettingsRow: NSView {
    private let stack = NSStackView()

    init(title: String,
         subtitle: String? = nil,
         subtitleView: NSView? = nil,
         leading: NSView? = nil,
         trailing: [NSView] = [],
         subtitleWidth: CGFloat = 430,
         verticalInset: CGFloat = SettingsStyle.rowVerticalInset) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsStyle.rowHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsStyle.rowHorizontalInset)
        ])

        if let leading {
            leading.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(leading)
        }

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleField = SettingsText.rowTitle(title)
        textStack.addArrangedSubview(titleField)
        if let subtitle {
            let subtitleField = SettingsText.rowSubtitle(subtitle, width: subtitleWidth)
            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.widthAnchor.constraint(equalToConstant: subtitleWidth).isActive = true
            textStack.addArrangedSubview(subtitleField)
        }
        if let subtitleView {
            subtitleView.translatesAutoresizingMaskIntoConstraints = false
            subtitleView.widthAnchor.constraint(equalToConstant: subtitleWidth).isActive = true
            if let field = subtitleView as? NSTextField {
                field.preferredMaxLayoutWidth = subtitleWidth
            }
            textStack.addArrangedSubview(subtitleView)
        }
        stack.addArrangedSubview(textStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        stack.addArrangedSubview(spacer)

        if !trailing.isEmpty {
            let trailingStack = NSStackView(views: trailing)
            trailingStack.orientation = .horizontal
            trailingStack.alignment = .centerY
            trailingStack.spacing = SettingsStyle.controlSpacing
            trailingStack.setContentHuggingPriority(.required, for: .horizontal)
            trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(trailingStack)
        }

        // Контролы без собственной подписи связываются с заголовком строки.
        for control in trailing {
            guard control is NSSwitch || control is NSPopUpButton
                    || control is NSSlider || control is NSTextField
                    || control is NSStepper else { continue }
            control.setAccessibilityTitleUIElement(titleField)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Строка с произвольным содержимым (например, полем промпта или загрузкой).
final class SettingsContentRow: NSView {
    init(_ content: NSView,
         verticalInset: CGFloat = 10,
         horizontalInset: CGFloat = SettingsStyle.rowHorizontalInset) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Секция: заголовок, необязательное пояснение и карточка.
final class SettingsSection: NSStackView {
    init(title: String, note: String? = nil, card: NSView) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = SettingsStyle.sectionTitleSpacing

        addArrangedFullWidth(SettingsText.sectionTitle(title))
        if let note {
            let noteField = SettingsText.footnote(note)
            noteField.textColor = .secondaryLabelColor
            addArrangedFullWidth(noteField)
        }
        addArrangedFullWidth(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Раскрывающийся блок для второстепенных настроек.
final class SettingsDisclosure: NSStackView {
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let content = NSStackView()
    private let chevron = NSImageView()
    private var expanded = false

    init(title: String, content views: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true

        toggle.title = title
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 13)
        toggle.alignment = .left
        toggle.target = self
        toggle.action = #selector(toggleExpanded)

        let header = NSStackView(views: [chevron, toggle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        addArrangedFullWidth(header)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        views.forEach { content.addArrangedFullWidth($0) }
        content.isHidden = true
        addArrangedFullWidth(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleExpanded() {
        expanded.toggle()
        content.isHidden = !expanded
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
    }
}

// MARK: - Боковой список

final class SettingsSidebarItem: NSButton {
    let pageID: String
    var onMove: ((Int) -> Void)?
    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?

    var isSelectedPage = false {
        didSet { applyBackground() }
    }

    init(pageID: String, title: String, symbol: String, color: NSColor) {
        self.pageID = pageID
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        alignment = .left
        font = .systemFont(ofSize: 13)
        self.image = SettingsSidebarItem.icon(symbol: symbol, color: color)
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleProportionallyDown
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(title)
        setAccessibilityRole(.radioButton)
        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func icon(symbol: String, color: NSColor) -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
                glyph.isTemplate = false
                glyph.draw(in: NSRect(x: rect.minX + 4, y: rect.minY + 4, width: 12, height: 12))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1)
        case 126: onMove?(-1)
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyBackground()
    }

    private func applyBackground() {
        layer?.backgroundColor = isSelectedPage
            ? SettingsStyle.sidebarSelection.cgColor
            : (hovered ? SettingsStyle.sidebarHover.cgColor : NSColor.clear.cgColor)
        setAccessibilitySelected(isSelectedPage)
    }
}

final class SettingsSidebar: NSView {
    private struct Group {
        let title: String
        let label: NSTextField
        let items: [SettingsSidebarItem]
    }

    private let search = NSSearchField()
    private let stack = NSStackView()
    private let emptyLabel = SettingsText.footnote("Ничего не найдено")
    private var groups: [Group] = []
    private var items: [SettingsSidebarItem] = []
    private(set) var selectedID: String?

    var onSelect: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        search.placeholderString = "Поиск"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 12.5)
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            search.heightAnchor.constraint(equalToConstant: 26),

            stack.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            emptyLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])

        addGroup(title: "ОБЩИЕ", items: [
            ("general", "Основные", "gearshape.fill", NSColor.systemGray),
            ("hotkeys", "Хоткеи", "keyboard", NSColor.systemGray)
        ])
        addGroup(title: "РАСПОЗНАВАНИЕ", items: [
            ("models", "Распознавание", "waveform", NSColor.systemBlue),
            ("dictionary", "Словарь", "book.closed.fill", NSColor.systemTeal)
        ])
        addGroup(title: "AI", items: [
            ("providers", "Провайдеры", "sparkles", NSColor.systemPurple),
            ("ai", "Постобработка", "text.badge.checkmark", NSColor.systemPurple)
        ])
        addGroup(title: "ДАННЫЕ", items: [
            ("history", "История", "clock.fill", NSColor.systemOrange),
            ("api", "API", "network", NSColor.systemBlue)
        ])
    }

    private func addGroup(title: String, items definitions: [(String, String, String, NSColor)]) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)

        let groupItems = definitions.map { definition -> SettingsSidebarItem in
            let item = SettingsSidebarItem(pageID: definition.0,
                                           title: definition.1,
                                           symbol: definition.2,
                                           color: definition.3)
            item.target = self
            item.action = #selector(itemPressed(_:))
            item.onMove = { [weak self, weak item] delta in
                guard let self, let item else { return }
                self.moveSelection(from: item, delta: delta)
            }
            stack.addArrangedFullWidth(item)
            items.append(item)
            return item
        }
        // Отступ между группами.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 9).isActive = true
        stack.addArrangedSubview(spacer)
        groups.append(Group(title: title, label: label, items: groupItems))
    }

    @objc private func itemPressed(_ sender: SettingsSidebarItem) {
        onSelect?(sender.pageID)
    }

    private func moveSelection(from item: SettingsSidebarItem, delta: Int) {
        let visible = items.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0 === item } ?? 0
        let next = min(max(current + delta, 0), visible.count - 1)
        let target = visible[next]
        target.performClick(nil)
        window?.makeFirstResponder(target)
    }

    func select(_ id: String) {
        selectedID = id
        items.forEach { $0.isSelectedPage = $0.pageID == id }
    }

    @objc private func searchChanged() {
        applyFilter(search.stringValue)
    }

    func applyFilter(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var visibleCount = 0
        for group in groups {
            var groupVisible = false
            for item in group.items {
                let matches = query.isEmpty || item.title.lowercased().contains(query)
                item.isHidden = !matches
                if matches { groupVisible = true; visibleCount += 1 }
            }
            group.label.isHidden = !groupVisible
        }
        emptyLabel.isHidden = visibleCount > 0
    }
}

// MARK: - Нижняя панель

final class SettingsFooter: NSView {
    let resetButton: NSButton
    let cancelButton: NSButton
    let saveButton: NSButton
    let dirtyLabel: NSTextField
    private let separator = NSView()

    override init(frame: NSRect) {
        resetButton = SettingsText.secondaryButton("Сбросить раздел…", target: nil, action: nil)
        resetButton.isBordered = false
        resetButton.contentTintColor = .secondaryLabelColor
        cancelButton = NSButton(title: "Отмена", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        dirtyLabel = NSTextField(labelWithString: "Есть изменения")
        super.init(frame: frame)

        wantsLayer = true
        applyColors()

        separator.wantsLayer = true
        separator.layer?.backgroundColor = SettingsStyle.rowSeparator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        dirtyLabel.font = .systemFont(ofSize: 11)
        dirtyLabel.textColor = .secondaryLabelColor
        dirtyLabel.isHidden = true

        let stack = NSStackView(views: [resetButton, dirtyLabel, NSView(), cancelButton, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(14, after: resetButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        (stack.arrangedSubviews[2]).setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        separator.layer?.backgroundColor = SettingsStyle.rowSeparator.cgColor
    }

    private func applyColors() {
        layer?.backgroundColor = SettingsStyle.footerBackground.cgColor
    }
}


extension NSStackView {
    /// Добавляет элемент и растягивает его на всю ширину стека.
    func addArrangedFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
