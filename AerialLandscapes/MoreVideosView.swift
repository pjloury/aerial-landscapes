import SwiftUI
import AVKit

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var selectedVideos: Set<UUID> = []
    @State private var downloadingVideos: Set<UUID> = []
    @FocusState private var focusedVideoId: UUID?
    
    var allVideos: [VideoPlayerModel.VideoItem] {
        // Local videos first, followed by remote videos
        videoPlayerModel.videos.filter { $0.isLocal } + videoPlayerModel.remoteVideos
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 20) {
                ForEach(allVideos) { video in
                    VideoItemView(
                        video: video,
                        isSelected: selectedVideos.contains(video.id),
                        isDownloading: downloadingVideos.contains(video.id)
                    ) {
                        toggleVideo(video)
                    }
                    .focused($focusedVideoId, equals: video.id)
                }
            }
            .padding(40)
        }
        .onAppear {
            // Initialize selected videos with local videos
            selectedVideos = Set(videoPlayerModel.videos.filter { $0.isLocal }.map { $0.id })
            // Set initial focus to first video
            if let firstVideo = allVideos.first {
                focusedVideoId = firstVideo.id
            }
        }
    }
    
    private func toggleVideo(_ video: VideoPlayerModel.VideoItem) {
        if selectedVideos.contains(video.id) {
            selectedVideos.remove(video.id)
            videoPlayerModel.removeVideo(video)
        } else {
            selectedVideos.insert(video.id)
            if !video.isLocal {
                downloadingVideos.insert(video.id)
                // Start downloading/streaming
                videoPlayerModel.downloadAndAddVideo(video) { success in
                    downloadingVideos.remove(video.id)
                }
            } else {
                videoPlayerModel.addVideo(video)
            }
        }
    }
}

struct VideoItemView: View {
    let video: VideoPlayerModel.VideoItem
    let isSelected: Bool
    let isDownloading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Thumbnail
                AsyncImage(url: video.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
                .aspectRatio(16/9, contentMode: .fit)
                .cornerRadius(8)
                
                HStack {
                    // Title
                    Text(video.title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Checkbox
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .white : .gray)
                }
                
                if isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(12)
        }
        .buttonStyle(.card)
    }
}

#Preview {
    MoreVideosView(videoPlayerModel: VideoPlayerModel())
        .preferredColorScheme(.dark)
} 
