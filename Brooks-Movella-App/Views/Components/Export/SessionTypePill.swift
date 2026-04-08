import SwiftUI

/// Compact segmented toggle for switching session type (Run / Cal).
/// ~120px wide. Selected state has colored background, unselected is transparent.
struct SessionTypeToggle: View {
    let type: SessionType
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SessionType.allCases, id: \.self) { option in
                let isActive = option == type
                Button {
                    if !isActive { action() }
                } label: {
                    Text(option.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(isActive ? .white : .secondary)
                        .frame(width: 52, height: 24)
                        .background(isActive ? option.color : Color.clear)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(7)
        .animation(AppAnimation.standard, value: type)
    }
}
