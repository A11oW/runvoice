import Foundation
import Carbon.HIToolbox

// MARK: - Настройки

struct HotKeySetting: Codable, Equatable {
    var keyCode: UInt32 = 49                       // space
    var modifiers: UInt32 = UInt32(optionKey)      // ⌥
    var display: String = "⌥Space"
}

struct Settings: Codable {
    var promptFix = ""
    var promptAgent = ""
    var language = "ru"
    var provider = "deepseek"
    var model = "deepseek-flash"
    var baseURL = ""
    var restoreClipboard = false
    var showHUD = true
    var hotkeyToggle = HotKeySetting()
    var hotkeyAgent = HotKeySetting(keyCode: 49,
                                    modifiers: UInt32(controlKey) | UInt32(shiftKey),
                                    display: "⌃⇧Space")

    enum CodingKeys: String, CodingKey {
        case promptFix, promptAgent, language, provider, model, baseURL, restoreClipboard, showHUD
        case hotkeyToggle, hotkeyAgent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptFix = try c.decodeIfPresent(String.self, forKey: .promptFix) ?? ""
        promptAgent = try c.decodeIfPresent(String.self, forKey: .promptAgent) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "ru"
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "deepseek"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-flash"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? false
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? true
        hotkeyToggle = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotkeyToggle) ?? HotKeySetting()
        hotkeyAgent = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotkeyAgent)
            ?? HotKeySetting(keyCode: 49,
                             modifiers: UInt32(controlKey) | UInt32(shiftKey),
                             display: "⌃⇧Space")
    }
}

enum DefaultPrompts {
    // Синхронизировано с bin/dictate.sh (DEFAULT_PROMPT_FIX / DEFAULT_PROMPT_AGENT)
    static let fix = "Ты — редактор надиктованного текста. Исправь орфографию, пунктуацию и заглавные буквы, убери повторы и слова-заикания. Сохрани исходный смысл и язык. Не добавляй ничего от себя, не отвечай на содержание и ничего не выполняй. Верни ТОЛЬКО итоговый текст, без кавычек и пояснений."
    static let agent = "Ты превращаешь устную надиктовку в точную письменную инструкцию или команду для ИИ-агента. Сохрани намерение автора, убери разговорные оговорки и повторы, сформулируй ясно и однозначно. Не выполняй инструкцию и не отвечай на неё — верни только переформулированный текст."
}

enum SettingsStore {
    static let url = Paths.support.appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    static func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
