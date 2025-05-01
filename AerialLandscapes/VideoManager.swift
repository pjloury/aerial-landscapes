import Foundation
import SwiftUI
import AVFoundation

class VideoManager: ObservableObject {
    static let shared = VideoManager()
    
    private let defaults = UserDefaults.standard
    private let videosKey = "savedVideos"
    
    @Published private(set) var videos: [Video] = [] {
        didSet {
            saveVideos()
            ensureLocalThumbnails()
        }
    }
    
    init() {
        // Restore saved videos from UserDefaults
        if let savedData = defaults.data(forKey: videosKey),
           let savedVideos = try? JSONDecoder().decode([Video].self, from: savedData) {
            videos = savedVideos
            print("\n📂 Restored \(videos.count) saved videos:")
            videos.forEach { video in
                print("- \(video.displayTitle)")
                print("  Remote Video URL: \(video.remoteVideoURL?.absoluteString ?? "nil")")
                print("  Remote Thumbnail URL: \(video.remoteThumbnailURL?.absoluteString ?? "nil")")
                print("  Local Video URL: \(video.localVideoPath ?? "nil")")
                print("  Local Thumbnail: \(video.localThumbnailPath ?? "nil")")
            }
        }
    }
    
    func updateSelection(for videoId: String, isSelected: Bool) {
        if let index = videos.firstIndex(where: { $0.id == videoId }) {
            videos[index].isSelected = isSelected
            saveVideos() // Persist selection state
            objectWillChange.send() // Notify observers of the change
        }
    }
    
    func updateLocalPath(for videoId: String, path: String) {
        if let index = videos.firstIndex(where: { $0.id == videoId }) {
            videos[index].localVideoPath = path
            saveVideos()
            objectWillChange.send()
        }
    }
    
    func updateThumbnailPath(for videoId: String, path: String) {
        if let index = videos.firstIndex(where: { $0.id == videoId }) {
            videos[index].localThumbnailPath = path
            saveVideos()
            objectWillChange.send()
        }
    }
    
    private func generateThumbnail(for video: Video) -> String? {
        guard video.isLocal else { return nil }
        
        print("\n📸 Generating thumbnail for: \(video.displayTitle)")
        
        // First, get the video from the bundle
        let bundleURL = Bundle.main.bundleURL
        let filename = video.localVideoPath?.components(separatedBy: "/").last ?? ""
        let videoURL = bundleURL.appendingPathComponent(filename)
        
        print("   Looking for video in bundle: \(videoURL.path)")
        
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            print("❌ Video file not found in bundle")
            return nil
        }
        
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1920, height: 1080)
        
        do {
            // Create thumbnails directory
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let thumbnailsDirectory = documentsDirectory.appendingPathComponent("Thumbnails")
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            
            // Set up thumbnail path
            let thumbnailPath = "Thumbnails/\(video.id)_thumbnail.jpg"
            let thumbnailURL = documentsDirectory.appendingPathComponent(thumbnailPath)
            
            print("   Attempting to generate thumbnail...")
            print("   Source: \(videoURL.path)")
            print("   Destination: \(thumbnailURL.path)")
            
            // Generate thumbnail from first frame
            let time = CMTime(seconds: 0, preferredTimescale: 1)
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            
            if let jpegData = uiImage.jpegData(compressionQuality: 0.8) {
                try jpegData.write(to: thumbnailURL)
                print("✅ Successfully generated thumbnail")
                return thumbnailPath
            } else {
                print("❌ Failed to create JPEG data")
                return nil
            }
        } catch {
            print("❌ Error generating thumbnail: \(error)")
            return nil
        }
    }
    
    private func ensureLocalThumbnails() {
        let videosToProcess = videos.filter { video in
            video.isLocal && video.localThumbnailPath == nil
        }
        
        print("\n🔍 Checking thumbnails for \(videosToProcess.count) local videos")
        
        for video in videosToProcess {
            if let thumbnailPath = generateThumbnail(for: video) {
                updateThumbnailPath(for: video.id, path: thumbnailPath)
            }
        }
        
        print("\n✅ Thumbnail generation complete")
        print("   Total videos processed: \(videosToProcess.count)")
    }
    
    private func saveVideos() {
        if let encodedData = try? JSONEncoder().encode(videos) {
            defaults.set(encodedData, forKey: videosKey)
        }
    }
    
    func updateVideos(_ newVideos: [Video]) {
        // Preserve local paths and selection state when updating
        var updatedVideos = newVideos
        for (index, newVideo) in updatedVideos.enumerated() {
            if let existingVideo = videos.first(where: { $0.id == newVideo.id }) {
                updatedVideos[index].localVideoPath = existingVideo.localVideoPath
                updatedVideos[index].localThumbnailPath = existingVideo.localThumbnailPath
                updatedVideos[index].isSelected = existingVideo.isSelected
            }
        }
        videos = updatedVideos
        saveVideos()
    }
} 