import SwiftUI
import AVKit

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var selectedVideoIds: Set<String> = []
    @State private var downloadingVideoIds: Set<String> = []
    @FocusState private var focusedVideoId: String?
    
    // Add state to track the last focused video
    @State private var lastFocusedVideoId: String?
    
    var allVideos: [VideoPlayerModel.VideoItem] {
        // Get the list of downloaded video titles
        let downloadedTitles = Set(videoPlayerModel.videos.map { $0.title })
        
        // Create a dictionary of local videos by title for quick lookup
        let localVideosByTitle = Dictionary(uniqueKeysWithValues: 
            videoPlayerModel.videos.map { ($0.title, $0) }
        )
        
        // Combine bundled and remote videos in their original order
        let orderedVideos = videoPlayerModel.videos.filter { video in
            // Keep only bundled videos that aren't in remote list
            !videoPlayerModel.remoteVideos.contains { $0.title == video.title }
        } + videoPlayerModel.remoteVideos.map { remoteVideo in
            // For each remote video, use local version if downloaded, otherwise use remote
            if let localVideo = localVideosByTitle[remoteVideo.title] {
                return localVideo
            }
            return remoteVideo
        }
        
        return orderedVideos
    }
    
    // Group videos by section
    var videosBySection: [(String, [VideoPlayerModel.VideoItem])] {
        let grouped = Dictionary(grouping: allVideos) { $0.section }
        return grouped
            .map { (section, videos) in
                // Sort videos alphabetically within each section
                let sortedVideos = videos.sorted { $0.title < $1.title }
                return (section, sortedVideos)
            }
            .sorted { $0.0 < $1.0 } // Sort sections alphabetically
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(videosBySection, id: \.0) { section, videos in
                    VStack(alignment: .leading, spacing: 20) {
                        // Section Header
                        Text(section)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.leading, 60)
                        
                        // Videos Grid
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 40) {
                            ForEach(videos) { video in
                                VideoItemView(
                                    videoPlayerModel: videoPlayerModel,
                                    video: video,
                                    isSelected: selectedVideoIds.contains(video.id),
                                    isDownloading: downloadingVideoIds.contains(video.id)
                                ) {
                                    toggleVideo(video)
                                }
                                .focused($focusedVideoId, equals: video.id)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 60)
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
            
            videoPlayerModel.debugThumbnails()
        }
    }
    
    private func toggleVideo(_ video: VideoPlayerModel.VideoItem) {
        // Store the current focused video ID before any updates
        lastFocusedVideoId = focusedVideoId
        
        if selectedVideoIds.contains(video.id) {
            // Prevent toggling off if this is the last selected local video
            let selectedLocalVideos = allVideos.filter { selectedVideo in 
                selectedVideo.isLocal && selectedVideoIds.contains(selectedVideo.id)
            }
            if selectedLocalVideos.count <= 1 && video.isLocal {
                return // Don't allow toggling off the last video
            }
            
            selectedVideoIds.remove(video.id)
        } else {
            if video.isLocal {
                selectedVideoIds.insert(video.id)
            } else {
                // Start download for new video
                downloadingVideoIds.insert(video.id)
                videoPlayerModel.downloadAndAddVideo(video) { success in
                    DispatchQueue.main.async {
                        downloadingVideoIds.remove(video.id)
                        if success {
                            // Find the newly added local version
                            if let localVersion = videoPlayerModel.videos.first(where: { localVideo in
                                localVideo.title == video.title
                            }) {
                                selectedVideoIds.insert(localVersion.id)
                                // Update the video player
                                let selectedVideos = allVideos.filter { selectedVideo in
                                    selectedVideo.isLocal && selectedVideoIds.contains(selectedVideo.id)
                                }
                                videoPlayerModel.updateSelectedVideos(selectedVideos)
                                
                                // Restore focus to the last focused video
                                if let lastId = lastFocusedVideoId {
                                    focusedVideoId = lastId
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Update the video player with only local selected videos
        let selectedVideos = allVideos.filter { selectedVideo in
            selectedVideo.isLocal && selectedVideoIds.contains(selectedVideo.id)
        }
        videoPlayerModel.updateSelectedVideos(selectedVideos)
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
                // Thumbnail with loading overlay
                ZStack {
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
                    
                    // Show progress overlay when downloading
                    if isDownloading {
                        Rectangle()
                            .fill(Color.black.opacity(0.7))
                        if let progress = videoPlayerModel.downloadProgress[video.id] {
                            VStack {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .tint(.accentColor)
                                Text("\(Int(progress * 100))%")
                                    .foregroundColor(.white)
                            }
                            .padding()
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                    }
                }
                
                // Title and Selection Status
                HStack(alignment: .center) {
                    Text(video.title)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                    
                    if isDownloading {
                        // Show download progress
                        if let progress = videoPlayerModel.downloadProgress[video.id] {
                            Text("\(Int(progress * 100))%")
                                .foregroundColor(.gray)
                        }
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor(isSelected ? .white : .gray)
                    }
                }
                .frame(height: 60)
            }
            .padding(16)
            .background(Color.black.opacity(0.3))
            .cornerRadius(12)
        }
        .buttonStyle(.card)
        .disabled(isDownloading)
    }
}

#Preview {
    MoreVideosView(videoPlayerModel: VideoPlayerModel())
        .preferredColorScheme(.dark)
} 
