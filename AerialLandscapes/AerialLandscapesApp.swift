import SwiftUI

// Side Menu Tab Bar
// https://developer.apple.com/documentation/visionOS/destination-video

@main
struct AerialLandscapesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct S3ObjectMetadata {
    let key: String           // The S3 object key (filename)
    let displayTitle: String  // Human-readable title
    let geozone: String      // e.g., "California" or "International"
    
    // Helper to create from S3 headers
    static func from(headers: [AnyHashable: Any], key: String) -> S3ObjectMetadata? {
        guard let displayTitle = headers["x-amz-meta-display-title"] as? String,
              let geozone = headers["x-amz-meta-geozone"] as? String else {
            return nil
        }
        
        return S3ObjectMetadata(
            key: key,
            displayTitle: displayTitle,
            geozone: geozone
        )
    }
}

private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var objectURLs: [URL] = []
    var thumbnailURLs: [String: URL] = [:]
    var objectMetadata: [String: S3ObjectMetadata] = [:]
    
    private var currentElement: String?
    private var currentKey: String = ""
    private var currentMetadata: [String: String] = [:]
    private var isInMetadata = false
    
    init(bucketName: String, region: String) {
        self.bucketName = bucketName
        self.region = region
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        
        switch elementName {
        case "Key":
            currentKey = ""
        case "Metadata":
            isInMetadata = true
            currentMetadata = [:]
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let currentElement = currentElement else { return }
        
        if currentElement == "Key" {
            currentKey += string
        } else if isInMetadata {
            // Only store display-title and geozone metadata
            if currentElement == "display-title" || currentElement == "geozone" {
                currentMetadata[currentElement] = (currentMetadata[currentElement] ?? "") + string
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" {
            print("\n=== S3 Key Debug ===")
            print("Raw Key from XML: \(currentKey)")
            print("Metadata: \(currentMetadata)")
            
            // Only process if we have both required metadata fields
            if let displayTitle = currentMetadata["display-title"],
               let geozone = currentMetadata["geozone"] {
                
                let metadata = S3ObjectMetadata(
                    key: currentKey,
                    displayTitle: displayTitle,
                    geozone: geozone
                )
                
                let urlString = "https://\(bucketName).s3.\(region).amazonaws.com/\(currentKey)"
                if let url = URL(string: urlString) {
                    if currentKey.lowercased().hasSuffix(".jpg") {
                        // This is a thumbnail
                        let videoName = currentKey.replacingOccurrences(of: "_thumbnail.jpg", with: "")
                        thumbnailURLs[videoName] = url
                        objectMetadata[videoName] = metadata
                    } else {
                        // This is a video
                        objectURLs.append(url)
                        objectMetadata[currentKey] = metadata
                    }
                }
            } else {
                print("⚠️ Skipping object missing required metadata: \(currentKey)")
                print("Required: display-title and geozone")
                print("Found: \(currentMetadata)")
            }
        } else if elementName == "Metadata" {
            isInMetadata = false
        }
        
        if elementName == currentElement {
            currentElement = nil
        }
    }
}

private class ThumbnailCache {
    private let cacheDirectory: URL
    
    init() {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = baseCache.appendingPathComponent("VideoThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Private Helpers
    
    private func sanitizeFileName(_ title: String) -> String {
        // First, decode any existing percent encoding
        let decodedTitle = title.removingPercentEncoding ?? title
        // Then manually encode spaces only
        return decodedTitle.replacingOccurrences(of: " ", with: "%20")
    }
    
    private func getThumbnailURL(for videoTitle: String) -> URL {
        // First, decode any existing percent encoding
        let decodedTitle = videoTitle.removingPercentEncoding ?? videoTitle
        
        // Create the full filename with the thumbnail suffix
        let filename = "\(decodedTitle)_thumbnail.jpg"
        
        // Create URL directly with path to avoid double encoding
        let path = cacheDirectory.path + "/" + filename
            .replacingOccurrences(of: " ", with: "%20")
        
        return URL(fileURLWithPath: path)
    }
    
    private func isValidThumbnail(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[FileAttributeKey.size] as? Int64,
              size > 0 else {
            return false
        }
        return true
    }
    
    // MARK: - Public Methods
    
    func getCachedThumbnailURL(for videoTitle: String, verbose: Bool = true) -> URL? {
        let thumbnailURL = getThumbnailURL(for: videoTitle)
        
        if verbose {
            print("\n=== Thumbnail Cache Check for: \(videoTitle) ===")
            print("Sanitized path: \(thumbnailURL.lastPathComponent)")
            
            // List all files in cache directory for debugging
            if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                print("\nFiles in cache directory:")
                files.forEach { file in
                    print("- \(file.lastPathComponent)")
                }
            }
        }
        
        if isValidThumbnail(at: thumbnailURL) {
            if verbose {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
                   let size = attributes[FileAttributeKey.size] as? Int64 {
                    print("✅ Found valid cached thumbnail")
                    print("File size: \(size) bytes")
                }
            }
            return thumbnailURL
        }
        
        if verbose {
            print("❌ No valid cached thumbnail found")
        }
        return nil
    }
    
    func cacheThumbnailData(_ data: Data, for videoTitle: String) -> URL? {
        let thumbnailURL = getThumbnailURL(for: videoTitle)
        print("Saving thumbnail to: \(thumbnailURL.path)")
        
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: thumbnailURL)
            
            if isValidThumbnail(at: thumbnailURL) {
                print("✅ Successfully cached thumbnail for: \(videoTitle)")
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to write thumbnail data for \(videoTitle): \(error)")
        }
        return nil
    }
} 

