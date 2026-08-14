// DesignTokens.swift — Colors, fonts, and layout constants
//
// Ported from trcc_monitor.py color/layout definitions.
// All values match the Python prototype for visual consistency.

import AppKit
import CoreGraphics

// MARK: - Colors

enum Color {
    static let bgTop = CGColor(red: 10/255, green: 12/255, blue: 20/255, alpha: 1)
    static let bgBot = CGColor(red: 16/255, green: 18/255, blue: 28/255, alpha: 1)
    static let panelBG = CGColor(red: 20/255, green: 23/255, blue: 34/255, alpha: 1)
    static let border = CGColor(red: 38/255, green: 42/255, blue: 58/255, alpha: 1)

    static let textW = CGColor(red: 230/255, green: 235/255, blue: 245/255, alpha: 1)
    static let textS = CGColor(red: 140/255, green: 148/255, blue: 168/255, alpha: 1)
    static let textL = CGColor(red: 100/255, green: 108/255, blue: 130/255, alpha: 1)
    static let textD = CGColor(red: 70/255, green: 76/255, blue: 95/255, alpha: 1)

    static let blue = CGColor(red: 66/255, green: 133/255, blue: 244/255, alpha: 1)
    static let blueD = CGColor(red: 30/255, green: 60/255, blue: 120/255, alpha: 1)
    static let green = CGColor(red: 52/255, green: 211/255, blue: 153/255, alpha: 1)
    static let greenD = CGColor(red: 24/255, green: 95/255, blue: 70/255, alpha: 1)
    static let orange = CGColor(red: 251/255, green: 191/255, blue: 36/255, alpha: 1)
    static let orangeD = CGColor(red: 110/255, green: 84/255, blue: 16/255, alpha: 1)
    static let red = CGColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
    static let redD = CGColor(red: 110/255, green: 30/255, blue: 30/255, alpha: 1)
    static let purple = CGColor(red: 167/255, green: 139/255, blue: 250/255, alpha: 1)
    static let purpleD = CGColor(red: 75/255, green: 62/255, blue: 115/255, alpha: 1)
    static let cyan = CGColor(red: 34/255, green: 211/255, blue: 238/255, alpha: 1)
    static let cyanD = CGColor(red: 15/255, green: 95/255, blue: 108/255, alpha: 1)
    static let magenta = CGColor(red: 217/255, green: 70/255, blue: 239/255, alpha: 1)
    static let magentaD = CGColor(red: 80/255, green: 28/255, blue: 90/255, alpha: 1)
    static let claude = CGColor(red: 217/255, green: 119/255, blue: 87/255, alpha: 1)  // Claude brand terracotta
    // Cursor monochrome: near-white primary on the dark panel (Cursor's own UI is B/W)
    static let cursor = CGColor(red: 235/255, green: 235/255, blue: 240/255, alpha: 1)
    static let cursorDim = CGColor(red: 140/255, green: 142/255, blue: 150/255, alpha: 1)

    static let barBG = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)

    /// Color by percentage threshold: green < 50, orange < 75, red >= 75
    static func forPercent(_ pct: Double) -> CGColor {
        pct < 50 ? green : (pct < 75 ? orange : red)
    }

    static func forPercentDark(_ pct: Double) -> CGColor {
        pct < 50 ? greenD : (pct < 75 ? orangeD : redD)
    }

    /// Color by macOS memory pressure level (1=normal, 2=warn, 4=critical).
    /// Severity comes from pressure, not from used% — a Mac using RAM as cache is not "in danger".
    static func forPressure(_ level: Int) -> CGColor {
        level >= 4 ? red : (level >= 2 ? orange : green)
    }

    static func forPressureDark(_ level: Int) -> CGColor {
        level >= 4 ? redD : (level >= 2 ? orangeD : greenD)
    }
}

// MARK: - Layout

enum Layout {
    static let width = 1920
    static let height = 480
    static let margin = 14
    static let gap = 10
    static let panelCount = 5
    static let panelWidth = (width - 2 * margin - (panelCount - 1) * gap) / panelCount
    static let panelHeight = height - 2 * margin
    static let panelY = margin

    /// X position for panel at index (0-based)
    static func panelX(_ index: Int) -> Int {
        margin + index * (panelWidth + gap)
    }
}

// MARK: - Fonts

enum Fonts {
    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
    }

    nonisolated(unsafe) private static var cache: [FontKey: NSFont] = [:]

    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = FontKey(size: size, weight: weight)
        if let cached = cache[key] {
            return cached
        }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Brightness

enum Brightness {
    /// Brightness levels 1-10. Factor = 1.0 + (level-1) * 0.3
    static func factor(for level: Int) -> CGFloat {
        let clamped = max(1, min(10, level))
        return 1.0 + CGFloat(clamped - 1) * 0.3
    }
}
