import SwiftUI
import AVKit

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var selectedVideoIds: Set<String> = []
    @State private var downloadingVideoIds: Set<String> = []
    @FocusState private var focusedVideoId: UUID?
    
    var allVideos: [VideoPlayerModel.VideoItem] {
        // Local videos first, followed by remote videos, in fixed order
        videoPlayerModel.videos + videoPlayerModel.remoteVideos
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 40) {
                ForEach(allVideos) { video in
                    VideoItemView(
                        video: video,
                        isSelected: selectedVideoIds.contains(video.id.uuidString),
                        isDownloading: downloadingVideoIds.contains(video.id.uuidString)
                    ) {
                        toggleVideo(video)
                    }
                    .focused($focusedVideoId, equals: video.id)
                }
            }
            .padding(60)
        }
        .onAppear {
            // Load selected videos from UserDefaults
            if let selectedIds = UserDefaults.standard.array(forKey: "selectedVideoIds") as? [String] {
                selectedVideoIds = Set(selectedIds)
            } else {
                // First launch - select all local videos
                selectedVideoIds = Set(videoPlayerModel.videos.map { $0.id.uuidString })
                UserDefaults.standard.set(Array(selectedVideoIds), forKey: "selectedVideoIds")
            }
            
            // Set initial focus
            if let firstVideo = allVideos.first {
                focusedVideoId = firstVideo.id
            }
        }
    }
    
    private func toggleVideo(_ video: VideoPlayerModel.VideoItem) {
        if selectedVideoIds.contains(video.id.uuidString) {
            // Prevent toggling off if this is the last selected local video
            let selectedLocalVideos = allVideos.filter { 
                $0.isLocal && selectedVideoIds.contains($0.id.uuidString)
            }
            if selectedLocalVideos.count <= 1 && video.isLocal {
                return // Don't allow toggling off the last video
            }
            
            selectedVideoIds.remove(video.id.uuidString)
        } else {
            if video.isLocal {
                selectedVideoIds.insert(video.id.uuidString)
            } else {
                downloadingVideoIds.insert(video.id.uuidString)
                videoPlayerModel.downloadAndAddVideo(video) { success in
                    downloadingVideoIds.remove(video.id.uuidString)
                    if success {
                        selectedVideoIds.insert(video.id.uuidString)
                    }
                }
            }
        }
        
        // Update the video player with only local selected videos
        let selectedVideos = allVideos.filter { video in
            video.isLocal && selectedVideoIds.contains(video.id.uuidString)
        }
        videoPlayerModel.updateSelectedVideos(selectedVideos)
    }
}

struct VideoItemView: View {
    let video: VideoPlayerModel.VideoItem
    let isSelected: Bool
    let isDownloading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
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
                
                // Title and Selection Status
                HStack {
                    Text(video.title)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Spacer()
                    
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .white : .gray)
                }
                
                if isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(20)
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
