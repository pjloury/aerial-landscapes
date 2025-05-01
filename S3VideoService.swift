private class ThumbnailCache {
    private let cacheDirectory: URL
    
    init() {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = baseCache.appendingPathComponent("VideoThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func getCachedThumbnailURL(for videoTitle: String) -> URL? {
        // Try both encoded and unencoded paths
        let paths = [
            videoTitle,                                                            // Raw title
            videoTitle.replacingOccurrences(of: "%20", with: " "),               // Decode %20 to space
            videoTitle.replacingOccurrences(of: " ", with: "%20")                // Encode space to %20
        ]
        
        print("\n=== Thumbnail Cache Check for: \(videoTitle) ===")
        
        // List all files in cache directory for debugging
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            print("\nFiles in cache directory:")
            files.forEach { file in
                print("- \(file.lastPathComponent)")
            }
        }
        
        // Try each path variant
        for path in paths {
            let thumbnailURL = cacheDirectory.appendingPathComponent("\(path)_thumbnail.jpg")
            print("\nTrying path: \(thumbnailURL.path)")
            
            if FileManager.default.fileExists(atPath: thumbnailURL.path),
               let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
               let size = attributes[.size] as? Int64,
               size > 0 {
                print("✅ Found valid cached thumbnail")
                print("File size: \(size) bytes")
                return thumbnailURL
            }
        }
        
        print("❌ No valid cached thumbnail found")
        return nil
    }
    
    func cacheThumbnailData(_ data: Data, for videoTitle: String) -> URL? {
        // Don't encode here - use the raw title
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(videoTitle)_thumbnail.jpg")
        
        print("Saving thumbnail to: \(thumbnailURL.path)")
        
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: thumbnailURL)
            
            if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
               (attributes[.size] as? Int64 ?? 0) > 0 {
                print("✅ Successfully cached thumbnail for: \(videoTitle)")
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to write thumbnail data for \(videoTitle): \(error)")
        }
        return nil
    }
}

func refreshThumbnails(forceRefresh: Bool = false) {
    print("\n=== 🔄 Starting Thumbnail Refresh ===")
    print("Force refresh: \(forceRefresh)")
    
    for video in remoteVideos {
        print("\n🎥 Processing: \(video.title)")
        
        // First check for valid cached thumbnail
        if let cachedURL = thumbnailCache.getCachedThumbnailURL(for: video.title) {
            print("✅ Using cached thumbnail: \(cachedURL)")
            
            // Update the video item with the cached URL
            DispatchQueue.main.async {
                self.updateRemoteVideoThumbnail(for: video.title, with: .local(cachedURL))
            }
            
            // Skip download unless forced
            if !forceRefresh {
                continue
            }
        }
        
        // Only proceed with download if no cache or force refresh
        if let thumbnailURL = video.thumbnailInfo.url {
            print("Downloading from: \(thumbnailURL)")
            downloadAndCacheThumbnail(from: thumbnailURL, for: video.title)
        }
    }
}

// Add a struct to hold metadata
struct S3ObjectMetadata {
    let key: String
    let displayTitle: String
    let contentType: String
    let lastModified: Date?
    // Add other metadata fields as needed
}

private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var objectURLs: [URL] = []
    var thumbnailURLs: [String: URL] = [:]
    var objectMetadata: [String: S3ObjectMetadata] = [:] // Add metadata storage
    
    private var currentElement: String?
    private var currentKey: String = ""
    private var currentMetadata: [String: String] = [:] // For building metadata during parsing
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
            // Store metadata values
            currentMetadata[currentElement] = (currentMetadata[currentElement] ?? "") + string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" {
            print("\n=== S3 Key Debug ===")
            print("Raw Key from XML: \(currentKey)")
            print("Metadata: \(currentMetadata)")
            
            // Only process if we have required metadata
            if let displayTitle = currentMetadata["displayTitle"] {
                let urlString = "https://\(bucketName).s3.\(region).amazonaws.com/\(currentKey)"
                
                if let url = URL(string: urlString) {
                    // Create metadata object
                    let metadata = S3ObjectMetadata(
                        key: currentKey,
                        displayTitle: displayTitle,
                        contentType: currentMetadata["contentType"] ?? "",
                        lastModified: nil // Parse date if needed
                    )
                    
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
                print("⚠️ Skipping object without display title metadata: \(currentKey)")
            }
        } else if elementName == "Metadata" {
            isInMetadata = false
        }
        
        if elementName == currentElement {
            currentElement = nil
        }
    }
}

func testS3Listing() {
    print("\n=== Testing S3 Listing ===")
    s3Service.listObjects { [weak self] result in
        if let (urls, thumbnails) = result {
            print("\nFound \(urls.count) objects and \(thumbnails.count) thumbnails")
        } else {
            print("Failed to list objects")
        }
    }
}

// Update fetchAvailableVideos to use metadata
func fetchAvailableVideos(completion: @escaping (VideoFetchResult) -> Void) {
    print("\n=== 📱 Fetching Available S3 Videos with Metadata ===")
    
    s3Service.listObjects { [weak self] result in
        guard let self = self else { return }
        
        if let (urls, thumbnails, metadata) = result {
            let videoURLs = urls.filter { url in
                let lowercasePath = url.lastPathComponent.lowercased()
                return lowercasePath.hasSuffix(".mp4") || lowercasePath.hasSuffix(".mov")
            }
            
            print("\n📹 Found \(videoURLs.count) videos in S3:")
            
            let validVideos = videoURLs.compactMap { url -> VideoPlayerModel.VideoItem? in
                let fileKey = url.lastPathComponent
                
                // Only process videos with metadata
                guard let objectMetadata = metadata[fileKey] else {
                    print("⚠️ Skipping video without metadata: \(fileKey)")
                    return nil
                }
                
                print("\n🎥 Processing video: \(objectMetadata.displayTitle)")
                
                // ALWAYS check for cached thumbnail first
                if let cachedURL = self.thumbnailCache.getCachedThumbnailURL(for: objectMetadata.displayTitle) {
                    print("✅ Using existing cached thumbnail")
                    return VideoPlayerModel.VideoItem(
                        url: url,
                        title: objectMetadata.displayTitle,
                        isLocal: false,
                        thumbnailInfo: .local(cachedURL),
                        section: self.determineSection(objectMetadata.displayTitle)
                    )
                }
                
                // Then check for remote thumbnail
                if let remoteURL = thumbnails[objectMetadata.displayTitle] {
                    print("🌐 Using remote thumbnail")
                    return VideoPlayerModel.VideoItem(
                        url: url,
                        title: objectMetadata.displayTitle,
                        isLocal: false,
                        thumbnailInfo: .remote(remoteURL),
                        section: self.determineSection(objectMetadata.displayTitle)
                    )
                }
                
                print("⚠️ No thumbnail available")
                return VideoPlayerModel.VideoItem(
                    url: url,
                    title: objectMetadata.displayTitle,
                    isLocal: false,
                    thumbnailInfo: .notAvailable,
                    section: self.determineSection(objectMetadata.displayTitle)
                )
            }
            
            completion(.success(validVideos))
        } else {
            completion(.failure(NSError(domain: "S3VideoService", code: -1, 
                userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve videos from S3"])))
        }
    }
}

struct S3Service {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucketName: String
    
    func listObjects(completion: @escaping ((urls: [URL], thumbnails: [String: URL], metadata: [String: S3ObjectMetadata])?) -> Void) {
        // Create the request as before
        let amzDate = // ... existing date code ...
        let host = "\(bucketName).s3.\(region).amazonaws.com"
        let endpoint = "https://\(host)/"
        
        // Add metadata headers to the canonical request
        let canonicalRequest = [
            "GET",
            "/",
            "",
            "host:\(host)",
            "x-amz-content-sha256:UNSIGNED-PAYLOAD",
            "x-amz-date:\(amzDate)",
            "x-amz-metadata-directive:COPY",  // Add this line
            "",
            "host;x-amz-content-sha256;x-amz-date;x-amz-metadata-directive",  // Update signed headers
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        
        // ... rest of signing logic ...
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("COPY", forHTTPHeaderField: "x-amz-metadata-directive")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // ... existing response handling ...
        }
        
        task.resume()
    }
} 