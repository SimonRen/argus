import MagpieLiteCore
import SwiftUI

/// Colour tokens from the approved design (tech-design §6), light and dark.
struct Theme {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private func pick(_ light: Color, _ dark: Color) -> Color { self.dark ? dark : light }

    var text: Color { pick(Color(hex: 0x1D1D1F), Color(hex: 0xF5F5F7)) }
    var sub: Color { pick(Color(hex: 0x55555B), Color(hex: 0xB8B8BF)) }
    var ter: Color { pick(Color(hex: 0x6A6A70), Color(hex: 0xA2A2AA)) }
    var hair: Color { pick(.black.opacity(0.07), .white.opacity(0.08)) }
    var card: Color { pick(.white.opacity(0.75), .white.opacity(0.05)) }
    var track: Color { pick(.black.opacity(0.09), .white.opacity(0.13)) }
    var ok: Color { pick(Color(hex: 0x2F6FE0), Color(hex: 0x5B9BFF)) }
    var warn: Color { pick(Color(hex: 0xD9822B), Color(hex: 0xF0A14A)) }
    var low: Color { pick(Color(hex: 0xD23F3F), Color(hex: 0xFF6B6B)) }
    var barLow: Color { pick(Color(hex: 0xC2362F), Color(hex: 0xFF8A8A)) }
    var chip: Color { pick(.black.opacity(0.06), .white.opacity(0.09)) }
    var btn: Color { pick(.black.opacity(0.06), .white.opacity(0.11)) }
    var liveBg: Color { pick(Color(hex: 0x2F6FE0).opacity(0.12), Color(hex: 0x5B9BFF).opacity(0.18)) }
    var liveText: Color { pick(Color(hex: 0x1F56B8), Color(hex: 0xA3C6FF)) }
    var liveRow: Color { pick(Color(hex: 0x2F6FE0).opacity(0.05), Color(hex: 0x5B9BFF).opacity(0.07)) }
    var notice: Color { pick(Color(hex: 0x2F6FE0).opacity(0.10), Color(hex: 0x5B9BFF).opacity(0.14)) }
    var deadBg: Color { pick(Color(hex: 0xD23F3F).opacity(0.10), Color(hex: 0xFF6B6B).opacity(0.15)) }
    var deadText: Color { pick(Color(hex: 0xB02E2E), Color(hex: 0xFFA3A3)) }
    var warnBg: Color { pick(Color(hex: 0xD9822B).opacity(0.12), Color(hex: 0xF0A14A).opacity(0.14)) }
    var warnText: Color { pick(Color(hex: 0x8A4B0F), Color(hex: 0xF5C38A)) }
    var link: Color { pick(Color(hex: 0x2F6FE0), Color(hex: 0x86B5FF)) }

    func bar(_ band: Band) -> Color {
        switch band {
        case .ok: ok
        case .warn: warn
        case .low: low
        case .empty: track
        }
    }

    static func accent(_ tool: Tool) -> Color {
        switch tool {
        case .claude: Color(hex: 0xC96442)
        case .codex: Color(hex: 0x2B8A78)
        case .agy: Color(hex: 0x3B74E0)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
