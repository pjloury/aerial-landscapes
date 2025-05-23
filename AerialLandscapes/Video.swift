import Foundation
import SwiftUI
import AVFoundation

struct Video: Identifiable, Codable {
    // Identity
    let id: String           // e.g., "FF001" from config or derived from S3 filename
    let displayTitle: String
    let geozone: String     // "domestic" or "international"
    
    // Paths
    let remoteVideoPath: String?     // Make optional
    let remoteThumbnailPath: String? // Make optional
    var localVideoPath: String?     // e.g., "Videos/FF001.mp4"
    var localThumbnailPath: String?  // Add this property
    
    // State
    var isSelected: Bool
    
    // Computed properties
    var isLocal: Bool { localVideoPath != nil }
    
    var url: URL {
        if let localPath = localVideoPath {
            // For local videos, we should use the bundle URL, not documents directory
            return Bundle.main.bundleURL.appendingPathComponent(
                localPath.components(separatedBy: "/").last ?? ""
            )
        }
        guard let remotePath = remoteVideoPath else {
            fatalError("Video has neither local nor remote path")
        }
        return URL(string: "https://\(AWSCredentials.bucketName).s3.\(AWSCredentials.region).amazonaws.com/\(remotePath)")!
    }
    
    var remoteVideoURL: URL? {
        guard let remotePath = remoteVideoPath else { return nil }
        return URL(string: "https://\(AWSCredentials.bucketName).s3.\(AWSCredentials.region).amazonaws.com/\(remotePath)")
    }
    
    var remoteThumbnailURL: URL? {
        guard let thumbnailPath = remoteThumbnailPath else { return nil }
        return URL(string: "https://\(AWSCredentials.bucketName).s3.\(AWSCredentials.region).amazonaws.com/\(thumbnailPath)")
    }
    
    var title: String { displayTitle }
    
    // UI helper
    var displayTitleWithStatus: String {
        isLocal ? displayTitle : "\(displayTitle) (Remote)"
    }
    
    // Update the thumbnail URL logic
    var thumbnailURL: URL? {
        print("\n🔍 Getting thumbnail URL for video: \(displayTitle)")
        
        // 1. Check for existing local thumbnail
        if let localPath = localThumbnailPath {
            // Remove any "_thumbnail" suffix if it exists
            let cleanPath = localPath.replacingOccurrences(of: "_thumbnail.jpg", with: ".jpg")
            let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(cleanPath)
            
            print("📍 Found local thumbnail path: \(localPath)")
            print("📍 Clean path: \(cleanPath)")
            print("📍 Full local URL: \(localURL.path)")
            
            // Verify file exists
            if FileManager.default.fileExists(atPath: localURL.path) {
                print("✅ Local thumbnail file exists")
                return localURL
            } else {
                print("⚠️ Local thumbnail file not found at path")
            }
        } else {
            print("ℹ️ No local thumbnail path set")
        }
        
        // 2. If we have a local video, return nil to trigger placeholder
        if isLocal {
            print("📹 Video is local, returning nil to generate thumbnail")
            return nil
        }
        
        // 3. Fall back to remote thumbnail
        print("☁️ Using remote thumbnail URL: \(remoteThumbnailURL?.absoluteString ?? "nil")")
        return remoteThumbnailURL
    }
    
    // Create from VideoConfig metadata
    static func fromMetadata(_ metadata: VideoMetadata) -> Video {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        
        // Try both .mp4 and .mov extensions
        let possibleExtensions = ["mp4", "mov"]
        var foundFilename: String? = nil
        
        for ext in possibleExtensions {
            let filename = "\(metadata.filename).\(ext)"
            let videoURL = bundleURL.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: videoURL.path) {
                foundFilename = filename
                print("📍 Found local video: \(videoURL.path)")
                break
            }
        }
        
        // Create video with appropriate paths
        let video = Video(
            id: metadata.uuid,
            displayTitle: metadata.displayTitle,
            geozone: metadata.geozone,
            remoteVideoPath: nil,      // Always nil for local videos
            remoteThumbnailPath: nil,  // Always nil for local videos
            localVideoPath: foundFilename.map { "Videos/\($0)" },  // Store just the filename
            localThumbnailPath: nil,   // Will be generated by VideoManager
            isSelected: true
        )
        
        return video
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case displayTitle
        case geozone
        case remoteVideoPath
        case remoteThumbnailPath
        case localVideoPath
        case localThumbnailPath
        case isSelected
    }
}

extension AVAsset {
    func loadValuesSync(forKeys keys: [String]) throws {
        var error: NSError?
        let timeout = DispatchTime.now() + 5.0 // 5 second timeout
        let semaphore = DispatchSemaphore(value: 0)
        
        loadValuesAsynchronously(forKeys: keys) {
            semaphore.signal()
        }
        
        if semaphore.wait(timeout: timeout) == .timedOut {
            throw NSError(domain: "AVAsset", code: -1, 
                userInfo: [NSLocalizedDescriptionKey: "Timed out loading asset"])
        }
        
        for key in keys {
            var keysError: NSError?
            let status = statusOfValue(forKey: key, error: &keysError)
            if status == .failed {
                throw keysError ?? error ?? NSError(domain: "AVAsset", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to load asset values"])
            }
        }
    }
} 
