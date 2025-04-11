import SwiftUI
import AVKit

struct VideoSection: Equatable {
    let title: String
    let videos: [VideoPlayerModel.VideoItem]
    
    static func == (lhs: VideoSection, rhs: VideoSection) -> Bool {
        lhs.title == rhs.title && lhs.videos.map { $0.id } == rhs.videos.map { $0.id }
    }
}

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var selectedVideoIds: Set<String> = []
    @State private var downloadingVideoIds: Set<String> = []
    @State private var showingClearCacheAlert = false
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
        
        // Start with all local videos
        var orderedVideos = videoPlayerModel.videos
        
        // Add remote videos that aren't already local
        for remoteVideo in videoPlayerModel.remoteVideos {
            if !downloadedTitles.contains(remoteVideo.title) {
                orderedVideos.append(remoteVideo)
            }
        }
        
        print("\n📊 Video List Status:")
        print("Local videos: \(videoPlayerModel.videos.count)")
        print("Remote videos: \(videoPlayerModel.remoteVideos.count)")
        print("Total unique videos: \(orderedVideos.count)")
        
        return orderedVideos
    }
    
    // Update the videosBySection computed property
    var videosBySection: [VideoSection] {
        let grouped = Dictionary(grouping: allVideos) { $0.section }
        return grouped
            .map { section, videos in
                // Sort videos alphabetically within each section
                let sortedVideos = videos.sorted { $0.title < $1.title }
                return VideoSection(title: section, videos: sortedVideos)
            }
            .sorted { $0.title < $1.title } // Sort sections alphabetically
    }
    
    var body: some View {
        VStack {
            // Add Clear Cache button at the top
            HStack {
                Spacer()
                Button(action: {
                    showingClearCacheAlert = true
                }) {
                    Label("Clear Cache", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .padding(.trailing, 60)
                .padding(.top, 20)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(videosBySection, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 20) {
                            // Section Header
                            Text(section.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.leading, 60)
                            
                            // Videos Grid with loading state
                            if videoPlayerModel.isInitialLoad && section.videos.isEmpty {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .frame(maxWidth: .infinity, maxHeight: 200)
                            } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 40) {
                                    ForEach(section.videos) { video in
                                        VideoItemView(
                                            videoPlayerModel: videoPlayerModel,
                                            video: video,
                                            isSelected: selectedVideoIds.contains(video.id),
                                            isDownloading: downloadingVideoIds.contains(video.id)
                                        ) {
                                            toggleVideo(video)
                                        }
                                        .focused($focusedVideoId, equals: video.id)
                                        .transition(.opacity)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 60)
            .animation(.easeInOut, value: videosBySection)
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
            
            // Debug current thumbnail state
            videoPlayerModel.debugThumbnails()
            
            // Force refresh thumbnails if any are missing
            videoPlayerModel.s3VideoService.refreshThumbnails(forceRefresh: true)
        }
        .alert("Clear Cache?", isPresented: $showingClearCacheAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                videoPlayerModel.clearCache()
            }
        } message: {
            Text("This will remove all downloaded videos and thumbnails. You'll need to download them again.")
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
            
            // Update the video player with current selection
            let currentSelectedVideos = allVideos.filter { selectedVideo in
                selectedVideo.isLocal && selectedVideoIds.contains(selectedVideo.id)
            }
            videoPlayerModel.updateSelectedVideos(currentSelectedVideos)
        } else {
            if video.isLocal {
                selectedVideoIds.insert(video.id)
                
                // Update the video player with current selection
                let currentSelectedVideos = allVideos.filter { selectedVideo in
                    selectedVideo.isLocal && selectedVideoIds.contains(selectedVideo.id)
                }
                videoPlayerModel.updateSelectedVideos(currentSelectedVideos)
            } else {
                // Start download for new video
                downloadingVideoIds.insert(video.id)
                print("\n🔍 Starting download debug check:")
                videoPlayerModel.debugVideoDownload(video)
                
                videoPlayerModel.downloadAndAddVideo(video) { success in
                    DispatchQueue.main.async {
                        downloadingVideoIds.remove(video.id)
                        if success {
                            print("\n🔍 Post-download debug check:")
                            videoPlayerModel.debugVideoDownload(video)
                            // Find the newly added local version
                            if let localVersion = videoPlayerModel.videos.first(where: { localVideo in
                                localVideo.title == video.title
                            }) {
                                // Automatically select the newly downloaded video
                                selectedVideoIds.insert(localVersion.id)
                                
                                // Get ALL currently selected local videos including the new one
                                let allSelectedVideos = allVideos.filter { selectedVideo in
                                    selectedVideo.isLocal && (
                                        selectedVideoIds.contains(selectedVideo.id)
                                    )
                                }
                                
                                print("\n🎬 Updating playlist after download:")
                                print("Total selected videos: \(allSelectedVideos.count)")
                                allSelectedVideos.forEach { video in
                                    print("- \(video.title) (Local: \(video.isLocal))")
                                }
                                
                                // Update UserDefaults with the new selection
                                UserDefaults.standard.set(
                                    Array(selectedVideoIds),
                                    forKey: "selectedVideoIds"
                                )
                                
                                // Update the video player with ALL selected videos
                                videoPlayerModel.updateSelectedVideos(allSelectedVideos)
                                
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
                    // Always show thumbnail if available
                    if let thumbnailURL = video.thumbnailURL {
                        AsyncImage(url: thumbnailURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fill)
                            case .failure(_):
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        Image(systemName: "photo.fill")
                                            .foregroundColor(.gray)
                                    )
                            case .empty:
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        ProgressView()
                                            .tint(.white)
                                    )
                            @unknown default:
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                            }
                        }
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(8)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(8)
                            .overlay(
                                Image(systemName: "photo.fill")
                                    .foregroundColor(.gray)
                            )
                    }
                    
                    // Show download progress overlay
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
                    
                    // Show download icon only for non-local, non-downloading videos
                    if !video.isLocal && !isDownloading {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "icloud.and.arrow.down")
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(8)
                                    .padding(8)
                            }
                        }
                    }
                }
                
                // Title and Selection Status
                HStack(alignment: .center) {
                    Text(video.displayTitle)
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
