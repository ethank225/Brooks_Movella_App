import SwiftUI

struct InstructionBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.purple)
            Text("Name each runner and assign 3 DOTs")
                .font(.subheadline)
                .foregroundColor(.purple)
            Spacer()
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.12), Color.blue.opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
    }
}
