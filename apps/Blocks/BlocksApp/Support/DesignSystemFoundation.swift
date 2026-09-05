import AppKit
import SwiftUI

enum BlocksVisualTokens {
  enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

  }

  enum CornerRadius {
    static let small: CGFloat = 6
    static let control: CGFloat = 8
    static let section: CGFloat = 12
    static let large: CGFloat = 16
    static let pill: CGFloat = 999

  }

  enum Control {
    static let minimumHitTarget: CGFloat = 36
    static let standardHeight: CGFloat = 36
    static let compactHeight: CGFloat = 28
    static let compactIconSize: CGFloat = 13
    static let settingsRowMinimumHeight: CGFloat = 44
  }

  enum Density: String, CaseIterable, Sendable {
    case micro
    case compact
    case standard
    case content

    var controlHeight: CGFloat {
      switch self {
      case .micro, .compact:
        Control.compactHeight
      case .standard, .content:
        Control.standardHeight
      }
    }

    var contentSpacing: CGFloat {
      switch self {
      case .micro:
        Spacing.xxs
      case .compact:
        Spacing.xs
      case .standard:
        Spacing.sm
      case .content:
        Spacing.md
      }
    }
  }

  enum Stroke {
    static let subtleOpacity: CGFloat = 0.08
    static let activeOpacity: CGFloat = 0.18
    static let width: CGFloat = 1
    static let insertionIndicatorWidth: CGFloat = 2
  }

  enum Typography {
    static let caption: CGFloat = 11
    static let body: CGFloat = 13
    static let title: CGFloat = 17
    static let pageTitle: CGFloat = 22
  }

  enum Elevation {
    static let interactiveShadowOpacity: CGFloat = 0.08
    static let panelShadowOpacity: CGFloat = 0.14
    static let interactiveShadowRadius: CGFloat = 8
    static let panelShadowRadius: CGFloat = 18
    static let interactiveShadowY: CGFloat = 3
    static let panelShadowY: CGFloat = 8
  }

  enum Layout {
    static let settingsFormContentMaxWidth: CGFloat = 820
    static let settingsCollectionContentMaxWidth: CGFloat = 1120
    static let settingsSheetMinimumWidth: CGFloat = 560
    static let settingsSheetIdealWidth: CGFloat = 600
    static let settingsSheetCompactMinimumHeight: CGFloat = 280
    static let settingsSheetContentMaxWidth: CGFloat = 640
    static let settingsTrailingColumnMinimumWidth: CGFloat = 220
    static let settingsTrailingColumnWidth: CGFloat = 280
    static let settingsTrailingColumnMaximumWidth: CGFloat = 360
    static let settingsLabelMinimumWidth: CGFloat = 260
    static let settingsPageHorizontalPadding: CGFloat = 28
  }
}

enum BlocksInteractionState: String, CaseIterable, Sendable {
  case idle
  case hovered
  case pressed
  case focused
  case selected
  case disabled
  case loading
  case success
  case warning
  case error

  var isInteractive: Bool {
    switch self {
    case .disabled, .loading:
      false
    default:
      true
    }
  }

  var isTransient: Bool {
    switch self {
    case .hovered, .pressed, .loading, .success, .warning, .error:
      true
    case .idle, .focused, .selected, .disabled:
      false
    }
  }
}

struct BlocksInteractionAppearance: Equatable, Sendable {
  let contentOpacity: CGFloat
  let fillOpacity: CGFloat
  let borderOpacity: CGFloat
  let showsProgress: Bool

  static func resolve(
    _ state: BlocksInteractionState,
    increasesContrast: Bool = false
  ) -> BlocksInteractionAppearance {
    switch state {
    case .idle:
      .init(contentOpacity: 1, fillOpacity: 0, borderOpacity: 0, showsProgress: false)
    case .hovered:
      .init(contentOpacity: 1, fillOpacity: 0.07, borderOpacity: 0, showsProgress: false)
    case .pressed:
      .init(contentOpacity: 1, fillOpacity: 0.14, borderOpacity: 0.18, showsProgress: false)
    case .focused:
      .init(
        contentOpacity: 1, fillOpacity: 0.07, borderOpacity: increasesContrast ? 1 : 0.70,
        showsProgress: false)
    case .selected:
      .init(
        contentOpacity: 1, fillOpacity: 0.16, borderOpacity: increasesContrast ? 0.68 : 0.38,
        showsProgress: false)
    case .disabled:
      .init(
        contentOpacity: increasesContrast ? 0.68 : 0.52, fillOpacity: 0, borderOpacity: 0,
        showsProgress: false)
    case .loading:
      .init(contentOpacity: 0.82, fillOpacity: 0.06, borderOpacity: 0, showsProgress: true)
    case .success:
      .init(contentOpacity: 1, fillOpacity: 0.12, borderOpacity: 0.24, showsProgress: false)
    case .warning:
      .init(contentOpacity: 1, fillOpacity: 0.12, borderOpacity: 0.24, showsProgress: false)
    case .error:
      .init(contentOpacity: 1, fillOpacity: 0.12, borderOpacity: 0.28, showsProgress: false)
    }
  }
}

enum BlocksMotionRole: CaseIterable, Equatable, Sendable {
  case press
  case hoverFocus
  case selection
  case reveal
  case reflow
  case panel
  case confirmation
  case directManipulation

  func policy(
    reduceMotion: Bool,
    phase: BlocksMotionPhase = .standard
  ) -> BlocksMotionPolicy {
    guard !reduceMotion else {
      return BlocksMotionPolicy(
        duration: reducedMotionDuration,
        curve: .easeOut,
        allowsSpatialMotion: false,
        allowsGlassMorph: false
      )
    }

    switch self {
    case .press:
      return BlocksMotionPolicy(
        duration: 0.08, curve: .easeOut, allowsSpatialMotion: false, allowsGlassMorph: false)
    case .hoverFocus:
      return BlocksMotionPolicy(
        duration: 0.10, curve: .easeOut, allowsSpatialMotion: false, allowsGlassMorph: false)
    case .selection:
      return BlocksMotionPolicy(
        duration: 0.14, curve: .easeInOut, allowsSpatialMotion: false, allowsGlassMorph: false)
    case .reveal, .reflow:
      return BlocksMotionPolicy(
        duration: 0.18, curve: .easeInOut, allowsSpatialMotion: true, allowsGlassMorph: false)
    case .panel:
      return BlocksMotionPolicy(
        duration: 0.22, curve: .easeInOut, allowsSpatialMotion: true, allowsGlassMorph: true)
    case .confirmation:
      return BlocksMotionPolicy(
        duration: phase == .removal ? 0.12 : 0.16,
        curve: phase == .removal ? .easeIn : .easeOut,
        allowsSpatialMotion: true,
        allowsGlassMorph: false
      )
    case .directManipulation:
      return BlocksMotionPolicy(
        duration: 0, curve: .linear, allowsSpatialMotion: false, allowsGlassMorph: false)
    }
  }

  func animation(reduceMotion: Bool) -> Animation? {
    policy(reduceMotion: reduceMotion).animation
  }

  private var reducedMotionDuration: TimeInterval {
    switch self {
    case .directManipulation, .press:
      0
    default:
      0.10
    }
  }
}

enum BlocksMotionPhase: Equatable, Sendable {
  case standard
  case insertion
  case removal
}

struct BlocksMotionPolicy: Equatable, Sendable {
  enum Curve: Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
  }

  let duration: TimeInterval
  let curve: Curve
  let allowsSpatialMotion: Bool
  let allowsGlassMorph: Bool

  var animation: Animation? {
    guard duration > 0 else { return nil }
    switch curve {
    case .linear:
      return Animation.linear(duration: duration)
    case .easeIn:
      return Animation.easeIn(duration: duration)
    case .easeOut:
      return Animation.easeOut(duration: duration)
    case .easeInOut:
      return Animation.easeInOut(duration: duration)
    }
  }
}
