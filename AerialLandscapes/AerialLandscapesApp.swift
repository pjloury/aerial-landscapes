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
    var videos: [Video] = []
    
    init(bucketName: String, region: String) {
        self.bucketName = bucketName
        self.region = region
        super.init()
    }
    
    // Temporary storage during parsing
    private var currentKey: String = ""
    private var currentElement: String = ""
    private var currentMetadata: [String: String] = [:]
    private var isInMetadata = false
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        
        switch elementName {
        case "Key":
            currentKey = ""
        case "UserMetadata":
            isInMetadata = true
            currentMetadata = [:]
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentKey.isEmpty && currentElement == "Key" {
            currentKey = string
        } else if isInMetadata {
            switch currentElement {
            case "x-amz-meta-display-title":
                currentMetadata["display-title"] = string
            case "x-amz-meta-geozone":
                currentMetadata["geozone"] = string
            default:
                break
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Contents" {
            // Only process video files
            if currentKey.hasSuffix(".mp4") || currentKey.hasSuffix(".mov"),
               let displayTitle = currentMetadata["display-title"],
               let geozone = currentMetadata["geozone"] {
                
                let id = currentKey.replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: ".mov", with: "")
                
                let video = Video(
                    id: id,
                    displayTitle: displayTitle,
                    geozone: geozone,
                    remoteVideoPath: currentKey,
                    remoteThumbnailPath: "\(currentKey)_thumbnail.jpg",
                    localVideoPath: nil,
                    isSelected: false
                )
                videos.append(video)
                
                print("📼 Parsed video: \(displayTitle)")
                print("   Video URL: \(video.remoteVideoURL)")
                print("   Thumbnail URL: \(video.remoteThumbnailURL)")
                print("   Metadata: \(currentMetadata)")
            }
            
            // Reset for next item
            currentKey = ""
            currentMetadata = [:]
        } else if elementName == "UserMetadata" {
            isInMetadata = false
        }
        
        currentElement = ""
    }
} 

