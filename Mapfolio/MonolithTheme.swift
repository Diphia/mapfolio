import SwiftUI
import UIKit

enum MonolithPalette {
    static let canvas = Color(red: 0.031, green: 0.031, blue: 0.031)           // #080808
    static let canvasDeep = Color(red: 0.024, green: 0.024, blue: 0.024)       // #060606
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.051)          // #0E0E0D
    static let surfaceElevated = Color(red: 0.078, green: 0.078, blue: 0.075)  // #141413
    static let surfaceDock = Color(red: 0.035, green: 0.035, blue: 0.035).opacity(0.95)
    static let surfaceOverlay = Color(red: 0.055, green: 0.055, blue: 0.051).opacity(0.96)

    static let ink = Color(red: 0.957, green: 0.945, blue: 0.918)              // #F4F1EA
    static let inkPressed = Color(red: 0.875, green: 0.863, blue: 0.831)       // #DFDCD4
    static let inkOnInverted = Color(red: 0.031, green: 0.031, blue: 0.031)    // #080808
    static let inkSecondary = Color(red: 0.659, green: 0.643, blue: 0.608)     // #A8A49B
    static let inkMuted = Color(red: 0.486, green: 0.471, blue: 0.439)         // #7C7870
    static let inkFaint = Color(red: 0.302, green: 0.290, blue: 0.267)         // #4D4A44

    static let hairline = Color(red: 0.137, green: 0.133, blue: 0.125)         // #232220
    static let hairlineSubtle = Color(red: 0.114, green: 0.110, blue: 0.102)   // #1D1C1A
    static let hairlineStrong = Color(red: 0.220, green: 0.216, blue: 0.204)   // #383734

    static let destructive = Color(red: 0.851, green: 0.408, blue: 0.369)      // #D9685E

    // Functional calibration accuracy indicators
    static let accuracyGood = Color(red: 0.341, green: 0.722, blue: 0.529)     // #57B887
    static let accuracyFair = Color(red: 0.812, green: 0.651, blue: 0.361)     // #CFA65C
    static let accuracyHigh = Color(red: 0.851, green: 0.408, blue: 0.369)     // #D9685E

    // Antique paper sheet physical tones
    static let paperBase = Color(red: 0.890, green: 0.827, blue: 0.694)        // #E3D3B1
    static let paperEdgeTop = Color(red: 0.776, green: 0.698, blue: 0.545)     // #C6B28B
    static let paperEdgeDeep = Color(red: 0.490, green: 0.424, blue: 0.310)    // #7D6C4F
    static let paperEdgeDim = Color(red: 0.231, green: 0.220, blue: 0.196)     // #3B3832

    // UIKit equivalents for calibration canvas overlays
    static let uiInk = UIColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1.0)
    static let uiCanvas = UIColor(red: 0.031, green: 0.031, blue: 0.031, alpha: 1.0)
    static let uiSurface = UIColor(red: 0.059, green: 0.059, blue: 0.055, alpha: 0.96)
    static let uiHairline = UIColor(red: 0.220, green: 0.216, blue: 0.204, alpha: 1.0)
    static let uiAccuracyGood = UIColor(red: 0.341, green: 0.722, blue: 0.529, alpha: 1.0)
    static let uiAccuracyFair = UIColor(red: 0.812, green: 0.651, blue: 0.361, alpha: 1.0)
    static let uiAccuracyHigh = UIColor(red: 0.851, green: 0.408, blue: 0.369, alpha: 1.0)
}

struct MonolithInvertedButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(
                        !isEnabled
                            ? MonolithPalette.surfaceElevated
                            : (configuration.isPressed ? MonolithPalette.inkPressed : MonolithPalette.ink)
                    )
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                isEnabled ? Color.clear : MonolithPalette.hairline,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.99 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MonolithOutlineButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    var borderColor: Color = MonolithPalette.hairlineStrong
    var fillColor: Color = MonolithPalette.surface

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? MonolithPalette.surfaceElevated : fillColor)
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                configuration.isPressed ? MonolithPalette.ink.opacity(0.65) : borderColor,
                                lineWidth: 1
                            )
                    )
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MonolithSegmentCellButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? MonolithPalette.surfaceElevated : Color.clear)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
