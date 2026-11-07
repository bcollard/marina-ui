import SwiftUI

/// The app's areas, each with one accent colour and symbol, used for section
/// headers, card tints and detail-view titles so an area reads at a glance.
/// Status colours (green/orange/red) stay reserved for health.
enum UIZone {
    case vm, fleet, cluster, mirror, container, mounts

    var color: Color {
        switch self {
        case .vm: return .teal
        case .fleet: return .indigo
        case .cluster: return .blue
        case .mirror: return .orange
        case .container: return .purple
        case .mounts: return .brown
        }
    }

    var symbol: String {
        switch self {
        case .vm: return "desktopcomputer"
        case .fleet: return "square.stack.3d.up.fill"
        case .cluster: return "circle.grid.3x3.fill"
        case .mirror: return "shippingbox.fill"
        case .container: return "cube.fill"
        case .mounts: return "externaldrive.fill"
        }
    }
}

/// The zone's symbol on a tinted rounded tile.
struct ZoneIcon: View {
    let zone: UIZone
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: zone.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(zone.color.gradient))
    }
}

/// Small capsule naming a zone, e.g. "FLEET" before a fleet's name.
struct ZoneTag: View {
    let zone: UIZone
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(zone.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(zone.color.opacity(0.14)))
    }
}
