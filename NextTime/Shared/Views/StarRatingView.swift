import SwiftUI

/// Tap a star to rate; tap the current rating again to clear it.
struct StarRatingView: View {
    @Binding var rating: Int?
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rating = rating == star ? nil : star
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= (rating ?? 0) ? Color.orange : Color.secondary.opacity(0.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating.map { "\($0) of 5 stars" } ?? "Not rated")
    }
}

/// Read-only stars for lists.
struct StarsLabel: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
            }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement()
        .accessibilityLabel("\(rating) of 5 stars")
    }
}
