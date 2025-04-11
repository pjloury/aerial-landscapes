import Foundation

class VideoCacheManager {
    private let defaults = UserDefaults.standard
    private let videoMetadataKey = "videoMetadata"
    
    struct VideoMetadata: Codable {
        let title: String
        let remoteURL: URL
        let section: String
        let hasCachedThumbnail: Bool
        let isDownloaded: Bool
        let lastUpdated: Date
        
        var id: String {
            isDownloaded ? "local-\(title)" : "remote-\(title)"
        }
        
        // Add CodingKeys to handle URL encoding/decoding
        enum CodingKeys: String, CodingKey {
            case title
            case remoteURL
            case section
            case hasCachedThumbnail
            case isDownloaded
            case lastUpdated
        }
        
        // Custom init for decoding
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            remoteURL = try container.decode(URL.self, forKey: .remoteURL)
            section = try container.decode(String.self, forKey: .section)
            hasCachedThumbnail = try container.decode(Bool.self, forKey: .hasCachedThumbnail)
            isDownloaded = try container.decode(Bool.self, forKey: .isDownloaded)
            lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        }
        
        // Custom init for creating instances
        init(title: String, remoteURL: URL, section: String, hasCachedThumbnail: Bool, isDownloaded: Bool, lastUpdated: Date) {
            self.title = title
            self.remoteURL = remoteURL
            self.section = section
            self.hasCachedThumbnail = hasCachedThumbnail
            self.isDownloaded = isDownloaded
            self.lastUpdated = lastUpdated
        }
    }
    
    func saveVideoMetadata(_ metadata: [VideoMetadata]) {
        print("\n💾 Saving video metadata")
        print("Items to save: \(metadata.count)")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let encoded = try encoder.encode(metadata)
            defaults.set(encoded, forKey: videoMetadataKey)
            print("✅ Successfully saved metadata")
        } catch {
            print("❌ Failed to save metadata: \(error)")
        }
    }
    
    func loadVideoMetadata() -> [VideoMetadata] {
        print("\n📖 Loading video metadata")
        
        guard let data = defaults.data(forKey: videoMetadataKey) else {
            print("⚠️ No metadata found in UserDefaults")
            return []
        }
        
        do {
            let decoder = JSONDecoder()
            let metadata = try decoder.decode([VideoMetadata].self, from: data)
            print("✅ Successfully loaded \(metadata.count) items")
            return metadata
        } catch {
            print("❌ Failed to load metadata: \(error)")
            return []
        }
    }
    
    func clearMetadata() {
        print("\n🗑️ Clearing video metadata")
        defaults.removeObject(forKey: videoMetadataKey)
        print("✅ Metadata cleared")
    }
} 