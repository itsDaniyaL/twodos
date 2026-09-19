import SwiftUI

/// A partner, on the wrist: their picture when they have one, initials
/// otherwise.
///
/// The picture URL arrives in the payload from the phone and is loaded here
/// with `AsyncImage` — the URL is public and never changes for a given
/// picture, so the system cache keeps it after the first load and a glance at
/// the list costs no network. The initials underneath are what shows in the
/// meantime and for partners who have no picture, so a row never draws an
/// empty circle.
struct WatchAvatarView: View {
    let initials: String
    var imageURL: URL?
    var size: CGFloat = 16
    var tint: Color = Brand.meadow

    var body: some View {
        Circle()
            .fill(tint.opacity(0.85))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            .overlay {
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        }
                        // Loading and failure leave the initials showing.
                    }
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                }
            }
            .accessibilityHidden(true)
    }
}
