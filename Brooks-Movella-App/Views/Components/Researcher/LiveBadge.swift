import SwiftUI

struct LiveBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) live")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red)
                .clipShape(Capsule())
        }
    }
}
