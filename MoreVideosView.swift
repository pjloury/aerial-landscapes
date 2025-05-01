private func handleImagePhase(_ phase: AsyncImagePhase) -> some View {
    // Add debug logging
    print("\n🖼 Loading thumbnail for: \(video.title)")
    print("URL: \(video.thumbnailInfo.url?.absoluteString ?? "none")")
    
    switch phase {
    case .success(let image):
        print("✅ Successfully loaded thumbnail")
        return AnyView(
            image
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .clipped()
        )
    case .failure(let error):
        print("❌ Failed to load thumbnail: \(error.localizedDescription)")
        return AnyView(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    Image(systemName: "photo.fill")
                        .foregroundColor(.gray)
                )
        )
    // ... rest of the cases remain the same
    }
}

struct VideoItemView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    let video: VideoPlayerModel.VideoItem
    let isSelected: Bool
    let isDownloading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Add debug print for thumbnail URL
                ZStack {
                    switch video.thumbnailInfo {
                    case .local(let url):
                        print("🖼 Loading local thumbnail for \(video.title): \(url)")
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                print("⏳ Loading thumbnail for \(video.title)...")
                            case .success(let image):
                                print("✅ Successfully loaded thumbnail for \(video.title)")
                                handleImagePhase(.success(image))
                            case .failure(let error):
                                print("❌ Failed to load thumbnail for \(video.title): \(error)")
                                handleImagePhase(.failure(error))
                            @unknown default:
                                handleImagePhase(phase)
                            }
                        }
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(8)
                        
                    case .remote(let url):
                        print("🌐 Loading remote thumbnail for \(video.title): \(url)")
                        AsyncImage(url: url) { phase in
                            handleImagePhase(phase)
                        }
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(8)
                        
                    case .notAvailable:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(8)
                            .overlay(
                                Image(systemName: "photo.fill")
                                    .foregroundColor(.gray)
                            )
                    }
                    
                    // Rest of the view remains the same...
                }
            }
        }
    }
} 