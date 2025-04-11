import Foundation
import CommonCrypto
import AVFoundation
import UIKit

class S3VideoService: ObservableObject {
    private let s3Service: S3Service
    @Published var remoteVideos: [VideoPlayerModel.VideoItem] = []
    private let thumbnailCache: ThumbnailCache
    
    init() {
        self.s3Service = S3Service(
            accessKey: AWSCredentials.accessKey,
            secretKey: AWSCredentials.secretKey,
            region: AWSCredentials.region,
            bucketName: AWSCredentials.bucketName
        )
        self.thumbnailCache = ThumbnailCache()
    }
    
    func fetchAvailableVideos() {
        print("=== Starting S3 Bucket List Operation ===")
        print("Bucket: \(s3Service.bucketName)")
        print("Region: \(s3Service.region)")
        
        s3Service.listObjects { [weak self] result in
            if let (urls, thumbnails) = result {
                print("\n✅ Successfully retrieved \(urls.count) objects from S3")
                print("📸 Found \(thumbnails.count) thumbnail images")
                
                // Process only video files
                let videoURLs = urls.filter { url in
                    let lowercasePath = url.lastPathComponent.lowercased()
                    return lowercasePath.hasSuffix(".mp4") || lowercasePath.hasSuffix(".mov")
                }
                print("\nFound \(videoURLs.count) video files:")
                videoURLs.forEach { print("📹 \($0.lastPathComponent)") }
                
                // Convert URLs to VideoItems with thumbnails
                let videos = videoURLs.map { url in
                    let title = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "+", with: " ")
                    
                    // Get thumbnail URL if it exists
                    let thumbnailURL = thumbnails[title]
                    print("\n🔍 Processing video: \(title)")
                    print("🖼️ Thumbnail found: \(thumbnailURL != nil)")
                    
                    if let thumbURL = thumbnailURL {
                        // Download and cache the thumbnail
                        self?.downloadAndCacheThumbnail(from: thumbURL, for: title)
                    } else {
                        print("⚠️ No thumbnail found for: \(title)")
                    }
                    
                    // Check if we have a cached version
                    let cachedThumbURL = self?.thumbnailCache.getCachedThumbnailURL(for: title)
                    if cachedThumbURL != nil {
                        print("✅ Using cached thumbnail for: \(title)")
                    }
                    
                    // Determine section based on title
                    let section = self?.determineSection(title) ?? "California"
                    
                    return VideoPlayerModel.VideoItem(
                        url: url,
                        title: title,
                        isLocal: false,
                        thumbnailURL: cachedThumbURL ?? thumbnailURL,
                        section: section
                    )
                }
                
                DispatchQueue.main.async {
                    self?.remoteVideos = videos
                    print("\n📊 Summary:")
                    print("Total videos: \(videos.count)")
                    videos.forEach { video in
                        print("- \(video.title)")
                        print("  Section: \(video.section)")
                        print("  Thumbnail: \(video.thumbnailURL?.absoluteString ?? "none")")
                    }
                }
            } else {
                print("❌ Failed to retrieve objects from S3")
            }
            self?.testS3Access()
        }
    }
    
    private func downloadAndCacheThumbnail(from url: URL, for videoTitle: String) {
        print("\n📥 Downloading thumbnail for: \(videoTitle)")
        print("URL: \(url)")
        
        // Check if already cached
        if let cachedURL = thumbnailCache.getCachedThumbnailURL(for: videoTitle) {
            print("✅ Already cached at: \(cachedURL)")
            return
        }
        
        // Create signed request for thumbnail
        let request = s3Service.generateSignedRequest(for: url)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("❌ Thumbnail download failed for \(videoTitle): \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Response status: \(httpResponse.statusCode)")
                // Accept both 200 (OK) and 206 (Partial Content) as success
                if httpResponse.statusCode != 200 && httpResponse.statusCode != 206 {
                    print("⚠️ Unexpected status code")
                    print("Response Headers:")
                    httpResponse.allHeaderFields.forEach { print("\($0): \($1)") }
                    if let data = data, let errorString = String(data: data, encoding: .utf8) {
                        print("Error Response: \(errorString)")
                    }
                    return
                }
            }
            
            guard let imageData = data else {
                print("❌ No image data received for \(videoTitle)")
                return
            }
            
            print("📦 Received \(imageData.count / 1024)KB for thumbnail")
            
            // Cache the thumbnail
            if let thumbnailURL = self?.thumbnailCache.cacheThumbnailData(imageData, for: videoTitle) {
                print("💾 Cached thumbnail at: \(thumbnailURL)")
                
                // Update the video item with the cached thumbnail URL
                DispatchQueue.main.async {
                    self?.updateThumbnail(for: videoTitle, with: thumbnailURL)
                    print("✅ Updated UI with cached thumbnail for \(videoTitle)")
                }
            } else {
                print("❌ Failed to cache thumbnail for \(videoTitle)")
            }
        }
        
        task.resume()
    }
    
    private func determineSection(_ title: String) -> String {
        // Add California locations here
        let californiaKeywords = [
            "San Francisco", "Embarcadero", "Fort Funston", "Marin", "Stanford",
            "Salt Flats", "Sather", "Alabama Hills", "Northern Marin"
        ]
        
        return californiaKeywords.contains { title.contains($0) } ? "California" : "International"
    }
    
    private func generateMissingThumbnails(for videos: [VideoPlayerModel.VideoItem]) {
        print("\n🖼️ Starting thumbnail generation for \(videos.count) videos")
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3 // Limit concurrent downloads
        
        for video in videos {
            if thumbnailCache.getCachedThumbnailURL(for: video.title) == nil {
                print("📥 Queueing thumbnail generation for: \(video.title)")
                queue.addOperation { [weak self] in
                    self?.generateAndCacheThumbnail(for: video)
                }
            } else {
                print("✅ Found cached thumbnail for: \(video.title)")
            }
        }
    }
    
    private func generateAndCacheThumbnail(for video: VideoPlayerModel.VideoItem) {
        print("\n🎬 Starting thumbnail generation for: \(video.title)")
        
        // Use the signed request but modify the range
        var request = s3Service.generateSignedRequest(for: video.url)
        request.setValue("bytes=0-4194304", forHTTPHeaderField: "Range")  // 4MB chunk
        
        print("📝 Request headers:")
        request.allHTTPHeaderFields?.forEach { key, value in
            print("\(key): \(value)")
        }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 Response status: \(httpResponse.statusCode)")
                httpResponse.allHeaderFields.forEach { key, value in
                    print("\(key): \(value)")
                }
            }
            
            if let error = error {
                print("❌ Download failed for \(video.title): \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                print("❌ No data received for \(video.title)")
                return
            }
            
            print("📥 Received \(data.count / 1024)KB for \(video.title)")
            
            // Create temporary file for the video segment
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            
            do {
                try data.write(to: tempURL)
                print("💾 Saved temporary file for \(video.title)")
                
                // Generate thumbnail from the video segment
                let asset = AVURLAsset(url: tempURL)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                imageGenerator.maximumSize = CGSize(width: 640, height: 360)
                
                // Try multiple time points if first fails
                let timePoints = [0.1, 1.0, 2.0]
                
                for timePoint in timePoints {
                    let time = CMTime(seconds: timePoint, preferredTimescale: 600)
                    print("🎯 Attempting to extract frame at \(timePoint)s for \(video.title)")
                    
                    do {
                        let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                        print("✅ Successfully extracted frame at \(timePoint)s")
                        
                        // Cache the thumbnail
                        if let thumbnailURL = self?.thumbnailCache.cacheThumbnail(cgImage, for: video.title) {
                            print("💾 Cached thumbnail for \(video.title) at \(thumbnailURL.lastPathComponent)")
                            // Update the video item with the new thumbnail URL
                            DispatchQueue.main.async {
                                self?.updateThumbnail(for: video.title, with: thumbnailURL)
                                print("✅ Updated UI with thumbnail for \(video.title)")
                            }
                        } else {
                            print("❌ Failed to cache thumbnail for \(video.title)")
                        }
                        break
                    } catch {
                        print("⚠️ Failed at \(timePoint)s: \(error.localizedDescription)")
                        if timePoint == timePoints.last {
                            print("❌ All frame extraction attempts failed")
                        }
                    }
                }
            } catch {
                print("❌ Failed to save temporary file for \(video.title): \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    private func updateThumbnail(for videoTitle: String, with thumbnailURL: URL) {
        // Find and update the video item with the new thumbnail
        if let index = remoteVideos.firstIndex(where: { $0.title == videoTitle }) {
            var updatedVideo = remoteVideos[index]
            updatedVideo = VideoPlayerModel.VideoItem(
                url: updatedVideo.url,
                title: updatedVideo.title,
                isLocal: updatedVideo.isLocal,
                thumbnailURL: thumbnailURL,
                section: updatedVideo.section
            )
            remoteVideos[index] = updatedVideo
        }
    }
    
    func testS3Access() {
        print("\n=== 🧪 S3 Access Test Starting ===")
        
        // Test a specific video and thumbnail
        let testVideo = "Alabama Hills"
        let videoURL = URL(string: "https://pjloury-aerial.s3.us-west-2.amazonaws.com/\(testVideo).mp4")!
        let thumbnailURL = URL(string: "https://pjloury-aerial.s3.us-west-2.amazonaws.com/\(testVideo)_thumbnail.jpg")!
        
        print("\n🎥 Testing video access:")
        print("URL: \(videoURL)")
        
        var request = s3Service.generateSignedRequest(for: videoURL)
        request.setValue("bytes=0-1048576", forHTTPHeaderField: "Range")
        
        print("\n📝 Request Headers:")
        request.allHTTPHeaderFields?.forEach { print("\($0): \($1)") }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            print("\n📥 Video Response:")
            if let error = error {
                print("❌ Error: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Status Code: \(httpResponse.statusCode)")
                print("\nResponse Headers:")
                httpResponse.allHeaderFields.forEach { print("\($0): \($1)") }
                
                if let data = data {
                    if httpResponse.statusCode == 206 {
                        print("\n✅ Successfully downloaded \(data.count / 1024)KB of video")
                    } else if let errorString = String(data: data, encoding: .utf8) {
                        print("\n❌ Error Response:")
                        print(errorString)
                    }
                }
            }
        }.resume()
        
        // Test thumbnail
        print("\n🖼️ Testing thumbnail access:")
        print("URL: \(thumbnailURL)")
        
        let thumbRequest = s3Service.generateSignedRequest(for: thumbnailURL)
        print("\n📝 Request Headers:")
        thumbRequest.allHTTPHeaderFields?.forEach { print("\($0): \($1)") }
        
        URLSession.shared.dataTask(with: thumbRequest) { data, response, error in
            print("\n📥 Thumbnail Response:")
            if let error = error {
                print("❌ Error: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Status Code: \(httpResponse.statusCode)")
                print("\nResponse Headers:")
                httpResponse.allHeaderFields.forEach { print("\($0): \($1)") }
                
                if let data = data {
                    if httpResponse.statusCode == 206 {
                        print("\n✅ Successfully downloaded \(data.count / 1024)KB of thumbnail")
                    } else if let errorString = String(data: data, encoding: .utf8) {
                        print("\n❌ Error Response:")
                        print(errorString)
                    }
                }
            }
        }.resume()
    }
}

// S3Service implementation
private struct S3Service {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucketName: String
    
    func listObjects(completion: @escaping ((urls: [URL], thumbnails: [String: URL])?) -> Void) {
        // Create the exact format AWS expects for x-amz-date
        let amzDateFormatter = ISO8601DateFormatter()
        amzDateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        amzDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzDateFormatter.string(from: Date()).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        
        // Create date stamp (YYYYMMDD)
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: Date())
        
        let host = "\(bucketName).s3.\(region).amazonaws.com"
        let endpoint = "https://\(host)/"
        
        print("Making request with:")
        print("x-amz-date: \(amzDate)")  // Should look like: 20240229T123456Z
        print("DateStamp: \(dateStamp)") // Should look like: 20240229
        
        // Task 1: Create canonical request
        let canonicalRequest = [
            "GET",
            "/",
            "",
            "host:\(host)",
            "x-amz-content-sha256:UNSIGNED-PAYLOAD",
            "x-amz-date:\(amzDate)",
            "",
            "host;x-amz-content-sha256;x-amz-date",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        
        // Task 2: Create string to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(sha256(canonicalRequest))
        """
        
        // Task 3: Calculate signature
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        // Task 4: Create authorization header
        let authorizationHeader = """
        \(algorithm) \
        Credential=\(accessKey)/\(credentialScope), \
        SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
        Signature=\(signature)
        """
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        // Add debug logging
        print("\nRequest Headers:")
        request.allHTTPHeaderFields?.forEach { key, value in
            print("\(key): \(value)")
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Error listing objects: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 Response status code: \(httpResponse.statusCode)")
            }
            
            if let data = data {
                let parser = XMLParser(data: data)
                let delegate = S3ParserDelegate(bucketName: self.bucketName, region: self.region)
                parser.delegate = delegate
                parser.parse()
                
                print("Found objects:")
                delegate.objectURLs.forEach { print("- \($0)") }
                completion((delegate.objectURLs, delegate.thumbnailURLs))
            } else {
                print("❌ No data received")
                completion(nil)
            }
        }
        
        task.resume()
    }
    
    func generateSignedRequest(for url: URL) -> URLRequest {
        let host = "\(bucketName).s3.\(region).amazonaws.com"
        
        // Create the exact format AWS expects for x-amz-date
        let amzDateFormatter = ISO8601DateFormatter()
        amzDateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        amzDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzDateFormatter.string(from: Date()).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        
        // Create date stamp (YYYYMMDD)
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: Date())
        
        // Get the URI-encoded path component
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        
        // Task 1: Create canonical request with Range header
        let canonicalRequest = [
            "GET",
            encodedPath, // Use the encoded path here
            "",
            "host:\(host)",
            "range:bytes=0-2097152",
            "x-amz-content-sha256:UNSIGNED-PAYLOAD",
            "x-amz-date:\(amzDate)",
            "",
            "host;range;x-amz-content-sha256;x-amz-date",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        
        // Task 2: Create string to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(sha256(canonicalRequest))
        """
        
        // Task 3: Calculate signature
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        // Task 4: Create authorization header
        let authorizationHeader = """
        \(algorithm) \
        Credential=\(accessKey)/\(credentialScope), \
        SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
        Signature=\(signature)
        """
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("bytes=0-2097152", forHTTPHeaderField: "Range")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        return request
    }
    
    private func sha256(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func hmac(key: Data, data: String) -> Data {
        let strData = data.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            strData.withUnsafeBytes { dataPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                      keyPtr.baseAddress, key.count,
                      dataPtr.baseAddress, strData.count,
                      &hash)
            }
        }
        return Data(hash)
    }
}

// S3ParserDelegate implementation
private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var objectURLs: [URL] = []
    var thumbnailURLs: [String: URL] = [:] // Map video names to thumbnail URLs
    private var currentElement: String?
    private var currentKey: String = ""
    
    init(bucketName: String, region: String) {
        self.bucketName = bucketName
        self.region = region
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "Key" {
            currentKey = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "Key" {
            currentKey += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" {
            let urlString = "https://\(bucketName).s3.\(region).amazonaws.com/\(currentKey)"
            if let url = URL(string: urlString) {
                if currentKey.lowercased().hasSuffix(".jpg") {
                    // This is a thumbnail
                    let videoName = currentKey.replacingOccurrences(of: "_thumbnail.jpg", with: "")
                    thumbnailURLs[videoName] = url
                    print("Found thumbnail for video: \(videoName)")
                } else {
                    // This is a video
                    objectURLs.append(url)
                }
            }
        }
        if elementName == currentElement {
            currentElement = nil
        }
    }
}

// Thumbnail cache manager
private class ThumbnailCache {
    private let cacheDirectory: URL
    
    init() {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = baseCache.appendingPathComponent("VideoThumbnails")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func getCachedThumbnailURL(for videoTitle: String) -> URL? {
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(videoTitle)_thumbnail.jpg")
        return FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil
    }
    
    func cacheThumbnail(_ cgImage: CGImage, for videoTitle: String) -> URL? {
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(videoTitle)_thumbnail.jpg")
        
        #if os(tvOS)
        let image = UIImage(cgImage: cgImage)
        #else
        let image = NSImage(cgImage: cgImage, size: .zero)
        #endif
        
        #if os(tvOS)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: thumbnailURL)
            return thumbnailURL
        }
        #else
        if let data = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data),
           let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: thumbnailURL)
            return thumbnailURL
        }
        #endif
        
        return nil
    }
    
    func cacheThumbnailData(_ data: Data, for videoTitle: String) -> URL? {
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(videoTitle)_thumbnail.jpg")
        do {
            try data.write(to: thumbnailURL)
            return thumbnailURL
        } catch {
            print("❌ Failed to write thumbnail data: \(error)")
            return nil
        }
    }
}

// Add these extensions at the bottom of the file
private extension S3VideoService {
    func sha256(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    func hmac(key: Data, data: String) -> Data {
        let strData = data.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            strData.withUnsafeBytes { dataPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                      keyPtr.baseAddress, key.count,
                      dataPtr.baseAddress, strData.count,
                      &hash)
            }
        }
        return Data(hash)
    }
}

private extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
} 
