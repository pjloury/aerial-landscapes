import SwiftUI
import AVKit

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var selectedVideoIds: Set<String> = []
    @State private var downloadingVideoIds: Set<String> = []
    @FocusState private var focusedVideoId: String?
    
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
                        isSelected: selectedVideoIds.contains(video.id),
                        isDownloading: downloadingVideoIds.contains(video.id)
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
                selectedVideoIds = Set(videoPlayerModel.videos.map { $0.id })
                UserDefaults.standard.set(Array(selectedVideoIds), forKey: "selectedVideoIds")
            }
            
            // Set initial focus
            if let firstVideo = allVideos.first {
                focusedVideoId = firstVideo.id
            }
        }
    }
    
    private func toggleVideo(_ video: VideoPlayerModel.VideoItem) {
        if selectedVideoIds.contains(video.id) {
            // Prevent toggling off if this is the last selected local video
            let selectedLocalVideos = allVideos.filter { 
                $0.isLocal && selectedVideoIds.contains($0.id)
            }
            if selectedLocalVideos.count <= 1 && video.isLocal {
                return // Don't allow toggling off the last video
            }
            
            selectedVideoIds.remove(video.id)
        } else {
            if video.isLocal {
                selectedVideoIds.insert(video.id)
            } else {
                downloadingVideoIds.insert(video.id)
                videoPlayerModel.downloadAndAddVideo(video) { success in
                    downloadingVideoIds.remove(video.id)
                    if success {
                        selectedVideoIds.insert(video.id)
                    }
                }
            }
        }
        
        // Update the video player with only local selected videos
        let selectedVideos = allVideos.filter { video in
            video.isLocal && selectedVideoIds.contains(video.id)
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
                
                // Title and Selection Status
                HStack(alignment: .center) {
                    Text(video.title)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                    
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(isSelected ? .white : .gray)
                }
                .frame(height: 60)
                
                if isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(16)
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
