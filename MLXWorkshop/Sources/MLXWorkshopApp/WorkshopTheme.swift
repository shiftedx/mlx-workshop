import SwiftUI

enum WorkshopTheme {
  static let canvas = Color(red: 0.047, green: 0.051, blue: 0.058)
  static let chrome = Color(red: 0.064, green: 0.070, blue: 0.079)
  static let surface = Color(red: 0.082, green: 0.090, blue: 0.101)
  static let surfaceRaised = Color(red: 0.108, green: 0.117, blue: 0.131)
  static let surfaceSelected = Color(red: 0.105, green: 0.194, blue: 0.278)
  static let divider = Color(red: 0.175, green: 0.188, blue: 0.208)

  static let ink = Color(red: 0.925, green: 0.940, blue: 0.957)
  static let secondaryInk = Color(red: 0.680, green: 0.712, blue: 0.754)
  static let quietInk = Color(red: 0.500, green: 0.535, blue: 0.580)

  static let sky = Color(red: 0.235, green: 0.600, blue: 0.930)
  static let skyBright = Color(red: 0.355, green: 0.710, blue: 1.000)
  static let skyWash = Color(red: 0.090, green: 0.205, blue: 0.305)
  static let success = Color(red: 0.380, green: 0.790, blue: 0.520)
  static let warning = Color(red: 0.950, green: 0.690, blue: 0.300)
  static let danger = Color(red: 0.930, green: 0.390, blue: 0.455)

  static let radiusSmall: CGFloat = 6
  static let radiusMedium: CGFloat = 9
  static let radiusLarge: CGFloat = 12

  static let spaceXXS: CGFloat = 4
  static let spaceXS: CGFloat = 8
  static let spaceS: CGFloat = 12
  static let spaceM: CGFloat = 16
  static let spaceL: CGFloat = 24
  static let spaceXL: CGFloat = 32
}

struct PrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: WorkshopTheme.radiusSmall, style: .continuous)
          .fill(
            isEnabled
              ? (configuration.isPressed ? WorkshopTheme.sky : WorkshopTheme.skyBright)
              : WorkshopTheme.surfaceRaised)
      )
      .opacity(isEnabled ? 1 : 0.58)
      .contentShape(Rectangle())
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

struct QuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(configuration.isPressed ? WorkshopTheme.ink : WorkshopTheme.secondaryInk)
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: WorkshopTheme.radiusSmall, style: .continuous)
          .fill(configuration.isPressed ? WorkshopTheme.surfaceRaised : WorkshopTheme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: WorkshopTheme.radiusSmall, style: .continuous)
          .stroke(WorkshopTheme.divider, lineWidth: 1)
      )
      .contentShape(Rectangle())
  }
}

struct StatusPill: View {
  let text: String
  let symbol: String
  let color: Color

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
      .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
  }
}

struct PanelHeader: View {
  let title: String
  var detail: String? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Spacer()
      if let detail {
        Text(detail)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(WorkshopTheme.quietInk)
          .monospacedDigit()
      }
    }
  }
}
