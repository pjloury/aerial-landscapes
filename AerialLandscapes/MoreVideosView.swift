import SwiftUI
import AVKit

struct VideoSection: Equatable {
    let title: String
    let videos: [Video]
    
    static func == (lhs: VideoSection, rhs: VideoSection) -> Bool {
        lhs.title == rhs.title && lhs.videos.map { $0.id } == rhs.videos.map { $0.id }
    }
}

struct MoreVideosView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    @State private var downloadingVideoIds: Set<String> = []
    @FocusState private var focusedVideoId: String?
    
    var allVideos: [Video] {
        // Get the list of downloaded video titles
        let downloadedTitles = Set(videoPlayerModel.videos.map { $0.title })
        
        // Start with all local videos
        var orderedVideos = videoPlayerModel.videos
        
        // Add remote videos that aren't already local
        for remoteVideo in videoPlayerModel.remoteVideos {
            if !downloadedTitles.contains(remoteVideo.title) {
                orderedVideos.append(remoteVideo)
            }
        }
        
        return orderedVideos
    }
    
    var videosBySection: [VideoSection] {
        let grouped = Dictionary(grouping: allVideos) { $0.geozone }
        return grouped
            .map { geozone, videos in
                let sectionTitle = geozone == "domestic" ? "California" : "International"
                let sortedVideos = videos.sorted { $0.title < $1.title }
                return VideoSection(title: sectionTitle, videos: sortedVideos)
            }
            .sorted { $0.title < $1.title }
    }
    
    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(videosBySection, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 20) {
                            Text(section.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.leading, 60)
                            
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
                                            isSelected: video.isSelected,
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
            print("\n📊 Video List Status:")
            print("Local videos: \(videoPlayerModel.videos.count)")
            print("Remote videos: \(videoPlayerModel.remoteVideos.count)")
            print("Selected videos: \(videoPlayerModel.selectedVideos.map(\.displayTitle).joined(separator: ", "))")
            
            // Set initial focus
            if let firstVideo = allVideos.first {
                focusedVideoId = firstVideo.id
            }
        }
    }
    
    private func toggleVideo(_ video: Video) {
        videoPlayerModel.toggleVideoSelection(for: video.id)
    }
}

struct VideoItemView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    let video: Video
    let isSelected: Bool
    let isDownloading: Bool
    let action: () -> Void
    
    // Add state to track loading state
    @State private var isLoadingThumbnail = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Thumbnail with loading overlay
                ZStack {
                    AsyncImage(url: video.thumbnailURL) { phase in
                        Group {
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fill)
                                    .clipped()
                                    .onAppear {
                                        print("✅ Successfully loaded thumbnail from: \(video.thumbnailURL?.absoluteString ?? "nil")")
                                    }
                            case .failure(let error):
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        Image(systemName: "photo.fill")
                                            .foregroundColor(.gray)
                                    )
                                    .onAppear {
                                        isLoadingThumbnail = false
                                        print("❌ Failed to load thumbnail: \(error)")
                                        print("   URL: \(String(describing: video.thumbnailURL))")
                                        // Retry the thumbnail download if it failed
                                        if !isLoadingThumbnail {
                                            isLoadingThumbnail = true
                                            videoPlayerModel.ensureThumbnail(for: video)
                                        }
                                    }
                            case .empty:
                                ProgressView()
                                    .onAppear {
                                        if !isLoadingThumbnail {
                                            isLoadingThumbnail = true
                                            print("⏳ Loading thumbnail for: \(video.displayTitle)")
                                            print("🔗 Attempting to load URL: \(String(describing: video.thumbnailURL))")
                                        }
                                    }
                            @unknown default:
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .onAppear {
                                        print("⚠️ Unknown thumbnail loading state for: \(video.displayTitle)")
                                    }
                            }
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)
                    // Add id to force refresh when URL changes
                    .id(video.thumbnailURL?.absoluteString ?? video.id)
                    
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

// Helper extension to convert SwiftUI Image to UIImage
extension Image {
    func asUIImage() -> UIImage? {
        let controller = UIHostingController(rootView: self)
        let view = controller.view
        
        let targetSize = controller.view.intrinsicContentSize
        view?.bounds = CGRect(origin: .zero, size: targetSize)
        view?.backgroundColor = .clear
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            view?.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}

#Preview {
    MoreVideosView(videoPlayerModel: VideoPlayerModel())
        .preferredColorScheme(.dark)
} 
