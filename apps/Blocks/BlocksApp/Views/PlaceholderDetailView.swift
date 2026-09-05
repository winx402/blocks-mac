import SwiftUI

struct PlaceholderDetailView: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .blocksSurface(
            .panel,
            cornerRadius: BlocksVisualTokens.CornerRadius.large,
            padding: BlocksVisualTokens.Spacing.xxl
        )
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
