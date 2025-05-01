import Foundation
import CommonCrypto
import AVFoundation
import UIKit

enum VideoFetchResult {
    case success([VideoPlayerModel.VideoItem])
    case failure(Error)
}

class S3VideoService: ObservableObject {
    let s3Service: S3Service
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
    
    func fetchAvailableVideos(completion: @escaping (VideoFetchResult) -> Void) {
        print("\n=== 📱 Fetching Available S3 Videos ===")
        
        testS3Access()
        testS3Connection()

        s3Service.listObjects { [weak self] result in
            if let (urls, thumbnails) = result {
                // Process video files and match with thumbnails
                let videoURLs = urls.filter { url in
                    let lowercasePath = url.lastPathComponent.lowercased()
                    return lowercasePath.hasSuffix(".mp4") || lowercasePath.hasSuffix(".mov")
                }
                
                print("\n📹 Found \(videoURLs.count) videos in S3:")
                print("\n🖼 Found \(thumbnails.count) thumbnails in S3:")
                
                // Create videos and download their thumbnails
                let validVideos = videoURLs.compactMap { url -> VideoPlayerModel.VideoItem? in
                    let title = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "+", with: " ")
                    
                    guard let thumbnailURL = thumbnails[title] else {
                        print("⚠️ Warning: No thumbnail found for video: \(title)")
                        return nil
                    }
                    
                    let section = self?.determineSection(title) ?? "International"
                    
                    print("✅ Matched video and thumbnail for: \(title)")
                    print("   Video URL: \(url)")
                    print("   Thumbnail URL: \(thumbnailURL)")
                    
                    // Start thumbnail download immediately
                    self?.downloadAndCacheThumbnail(from: thumbnailURL, for: title)
                    
                    // Initially return video with S3 thumbnail URL
                    return VideoPlayerModel.VideoItem(
                        url: url,
                        title: title,
                        isLocal: false,
                        thumbnailInfo: .remote(thumbnailURL),
                        section: section
                    )
                }
                
                completion(.success(validVideos))
            } else {
                completion(.failure(NSError(domain: "S3VideoService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve videos from S3"])))
            }
        }
    }
    
    private func downloadAndCacheThumbnail(from url: URL, for videoTitle: String) {
        print("\n📥 Downloading thumbnail for: \(videoTitle)")
        print("URL: \(url)")
        
        // Check if already cached and valid
        if let cachedURL = thumbnailCache.getCachedThumbnailURL(for: videoTitle) {
            print("✅ Found valid cached thumbnail at: \(cachedURL)")
            
            // Update UI with cached thumbnail
            DispatchQueue.main.async { [weak self] in
                self?.updateRemoteVideoThumbnail(for: videoTitle, with: .local(cachedURL))
            }
            return
        }
        
        // Create signed request for thumbnail
        let request = s3Service.generateSignedRequest(for: url)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("❌ Thumbnail download failed for \(videoTitle): \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response type for \(videoTitle)")
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("❌ Invalid response status \(httpResponse.statusCode) for \(videoTitle)")
                return
            }
            
            guard let imageData = data, imageData.count > 0 else {
                print("❌ No valid image data received for \(videoTitle)")
                return
            }
            
            print("📦 Received \(imageData.count / 1024)KB for thumbnail")
            
            // Cache the thumbnail
            if let thumbnailURL = self?.thumbnailCache.cacheThumbnailData(imageData, for: videoTitle) {
                print("💾 Cached thumbnail at: \(thumbnailURL)")
                
                // Update the video item with the cached thumbnail URL
                DispatchQueue.main.async {
                    self?.updateRemoteVideoThumbnail(for: videoTitle, with: .local(thumbnailURL))
                    print("✅ Updated UI with cached thumbnail for \(videoTitle)")
                }
            } else {
                // If caching fails, fall back to remote URL
                DispatchQueue.main.async {
                    self?.updateRemoteVideoThumbnail(for: videoTitle, with: .remote(url))
                    print("⚠️ Falling back to remote thumbnail for \(videoTitle)")
                }
            }
        }
        
        task.resume()
    }
    
    private func updateRemoteVideoThumbnail(for videoTitle: String, with thumbnailInfo: VideoPlayerModel.VideoItem.ThumbnailInfo) {
        if let index = remoteVideos.firstIndex(where: { $0.title == videoTitle }) {
            let video = remoteVideos[index]
            remoteVideos[index] = VideoPlayerModel.VideoItem(
                url: video.url,
                title: video.title,
                isLocal: video.isLocal,
                thumbnailInfo: thumbnailInfo,
                section: video.section
            )
        }
    }
    
    private func determineSection(_ title: String) -> String {
        // California locations
        let californiaKeywords = [
            "San Francisco", "Embarcadero", "Fort Funston", "Marin",
            "Stanford", "Salt Flats", "Sather", "Alabama Hills",
            "Northern Marin", "California"
        ]
        
        // Check if the title contains any California keywords
        if californiaKeywords.contains(where: { title.contains($0) }) {
            return "California"
        }
        
        // All other videos go to International
        return "International"
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
                                self?.updateThumbnail(for: video.title, with: .local(thumbnailURL))
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
    
    private func updateThumbnail(for videoTitle: String, with thumbnailInfo: VideoPlayerModel.VideoItem.ThumbnailInfo) {
        if let index = remoteVideos.firstIndex(where: { $0.title == videoTitle }) {
            let video = remoteVideos[index]
            remoteVideos[index] = VideoPlayerModel.VideoItem(
                url: video.url,
                title: video.title,
                isLocal: video.isLocal,
                thumbnailInfo: thumbnailInfo,
                section: video.section
            )
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

    func testS3Connection() {
        print("\n=== 🧪 S3 Connection Test ===")
        print("Bucket: \(s3Service.bucketName)")
        print("Region: \(s3Service.region)")
        
        let timestamp = s3Service.getCurrentAWSTimestamp()
        let amzDate = timestamp.amzDate
        let dateStamp = timestamp.dateStamp
        
        let host = "\(s3Service.bucketName).s3.\(s3Service.region).amazonaws.com"
        let endpoint = "https://\(host)/"
        
        print("\nEndpoint: \(endpoint)")
        print("Date: \(amzDate)")
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        
        // Create canonical request and signature
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
        
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(s3Service.region)/s3/aws4_request"
        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(sha256(canonicalRequest))
        """
        
        let kDate = hmac(key: "AWS4\(s3Service.secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: s3Service.region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        let authorizationHeader = """
        \(algorithm) \
        Credential=\(s3Service.accessKey)/\(credentialScope), \
        SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
        Signature=\(signature)
        """
        
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        print("\nRequest Headers:")
        request.allHTTPHeaderFields?.forEach { key, value in
            print("\(key): \(value)")
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            print("\n=== Response ===")
            
            if let error = error {
                print("❌ Error: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Status Code: \(httpResponse.statusCode)")
                print("\nResponse Headers:")
                httpResponse.allHeaderFields.forEach { key, value in
                    print("\(key): \(value)")
                }
            }
            
            if let data = data, let xmlString = String(data: data, encoding: .utf8) {
                print("\nResponse Body:")
                print(xmlString)
            } else {
                print("No data received")
            }
        }
        
        task.resume()
    }
    
    func getThumbnailURL(for videoTitle: String) -> URL? {
        // First, encode spaces and special characters
        let encodedTitle = videoTitle
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: ",", with: "%2C")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoTitle
        
        let urlString = "https://\(s3Service.bucketName).s3.\(s3Service.region).amazonaws.com/\(encodedTitle)_thumbnail.jpg"
        print("Generated URL: \(urlString)")
        return URL(string: urlString)
    }
    
    func refreshThumbnails(forceRefresh: Bool = false) {
        print("\n=== 🔄 Starting Thumbnail Refresh ===")
        print("Force refresh: \(forceRefresh)")
        
        for video in remoteVideos {
            print("\n🎥 Processing: \(video.title)")
            print("Current thumbnail URL: \(video.thumbnailInfo.url?.absoluteString ?? "none")")
            
            if let cachedURL = thumbnailCache.getCachedThumbnailURL(for: video.title) {
                print("Found in cache: \(cachedURL)")
                if !forceRefresh {
                    print("Skipping refresh - using cached version")
                    continue
                }
            }
            
            if let thumbnailURL = video.thumbnailInfo.url {
                print("Downloading from: \(thumbnailURL)")
                downloadAndCacheThumbnail(from: thumbnailURL, for: video.title)
            } else {
                print("❌ No thumbnail URL available")
            }
        }
    }
    
    private func updateRemoteVideoThumbnails(with thumbnails: [String: URL]) {
        print("\n🔄 Updating remote video thumbnails")
        print("Received \(thumbnails.count) thumbnail updates")
        
        remoteVideos = remoteVideos.map { video -> VideoPlayerModel.VideoItem in
            if let newThumbnailURL = thumbnails[video.title] ?? thumbnailCache.getCachedThumbnailURL(for: video.title) {
                print("✅ Updated thumbnail for: \(video.title)")
                return VideoPlayerModel.VideoItem(
                    url: video.url,
                    title: video.title,
                    isLocal: video.isLocal,
                    thumbnailInfo: .remote(newThumbnailURL),
                    section: video.section
                )
            }
            return video
        }
    }
    
    func refreshThumbnails(forTitles titles: [String]) {
        print("\n=== 🔄 Refreshing Specific Thumbnails ===")
        print("Refreshing \(titles.count) thumbnails")
        
        for title in titles {
            print("\n🎥 Processing: \(title)")
            if let thumbnailURL = getThumbnailURL(for: title) {
                print("Downloading from: \(thumbnailURL)")
                
                // Create a fresh signed request for each thumbnail
                let request = s3Service.generateSignedRequest(for: thumbnailURL)
                
                URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        print("❌ Download failed for \(title): \(error.localizedDescription)")
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("❌ Invalid response type for \(title)")
                        return
                    }
                    
                    print("\nResponse Status: \(httpResponse.statusCode)")
                    
                    if httpResponse.statusCode == 200, let data = data {
                        print("✅ Received \(data.count / 1024)KB for \(title)")
                        if let thumbnailURL = self.thumbnailCache.cacheThumbnailData(data, for: title) {
                            print("💾 Cached thumbnail at: \(thumbnailURL)")
                            DispatchQueue.main.async {
                                self.updateRemoteVideoThumbnail(for: title, with: .local(thumbnailURL))
                            }
                        }
                    } else if let errorData = data, let errorString = String(data: errorData, encoding: .utf8) {
                        print("❌ Error response for \(title):")
                        print(errorString)
                    }
                }.resume()
            } else {
                print("❌ Could not generate thumbnail URL for: \(title)")
            }
        }
    }
}

// S3Service implementation
struct S3Service {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucketName: String
    
    func getCurrentAWSTimestamp() -> (amzDate: String, dateStamp: String) {
        let currentDate = Date()
        
        // Format for x-amz-date: YYYYMMDD'T'HHMMSS'Z'
        let amzDateFormatter = ISO8601DateFormatter()
        amzDateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        amzDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzDateFormatter.string(from: currentDate)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        
        // Format for DateStamp: YYYYMMDD
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: currentDate)
        
        return (amzDate, dateStamp)
    }
    
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
        let path = url.path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        
        // Create canonical headers (note the ordering is important)
        let canonicalHeaders = [
            "host:\(host)",
            "x-amz-content-sha256:UNSIGNED-PAYLOAD",
            "x-amz-date:\(amzDate)"
        ].sorted().joined(separator: "\n") + "\n"
        
        // Create signed headers (must be sorted)
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        
        // Task 1: Create canonical request
        let canonicalRequest = [
            "GET",
            encodedPath,
            "", // Query string (empty in this case)
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        
        // Task 2: Create string to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            credentialScope,
            sha256(canonicalRequest)
        ].joined(separator: "\n")
        
        // Task 3: Calculate signature
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        // Task 4: Create authorization header (note the exact spacing and format)
        let authorizationHeader = "\(algorithm) " +
            "Credential=\(accessKey)/\(credentialScope)," +
            "SignedHeaders=\(signedHeaders)," +
            "Signature=\(signature)"
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        // Add debug logging
        print("\nRequest URL: \(url)")
        print("Authorization: \(authorizationHeader)")
        print("\nHeaders:")
        request.allHTTPHeaderFields?.forEach { key, value in
            print("\(key): \(value)")
        }
        
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
        cacheDirectory = baseCache.appendingPathComponent("VideoThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func getCachedThumbnailURL(for videoTitle: String) -> URL? {
        // Sanitize the filename to handle special characters
        let sanitizedTitle = videoTitle
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoTitle
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(sanitizedTitle)_thumbnail.jpg")
        
        // Verify file exists and is readable
        if FileManager.default.fileExists(atPath: thumbnailURL.path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
           (attributes[.size] as? Int64 ?? 0) > 0 {
            return thumbnailURL
        }
        return nil
    }
    
    func cacheThumbnailData(_ data: Data, for videoTitle: String) -> URL? {
        // Sanitize the filename to handle special characters
        let sanitizedTitle = videoTitle
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoTitle
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(sanitizedTitle)_thumbnail.jpg")
        
        do {
            // Create intermediate directories if needed
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            
            // Write the data
            try data.write(to: thumbnailURL)
            
            // Verify the file was written successfully
            if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
               (attributes[.size] as? Int64 ?? 0) > 0 {
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to write thumbnail data for \(videoTitle): \(error)")
        }
        return nil
    }
    
    func cacheThumbnail(_ cgImage: CGImage, for videoTitle: String) -> URL? {
        // Convert CGImage to UIImage
        let uiImage = UIImage(cgImage: cgImage)
        
        // Convert to JPEG data with high quality
        guard let imageData = uiImage.jpegData(compressionQuality: 0.9) else {
            print("❌ Failed to convert image to JPEG data for \(videoTitle)")
            return nil
        }
        
        // Use existing method to cache the data
        return cacheThumbnailData(imageData, for: videoTitle)
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
