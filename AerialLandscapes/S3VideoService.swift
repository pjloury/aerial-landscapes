import Foundation
import CommonCrypto
import AVFoundation
import UIKit

enum VideoFetchResult {
    case success([Video])
    case failure(Error)
}

class S3VideoService: ObservableObject {
    let s3Service: S3Service
    @Published private(set) var remoteVideos: [Video] = []
    
    init() {
        self.s3Service = S3Service(
            accessKey: AWSCredentials.accessKey,
            secretKey: AWSCredentials.secretKey,
            region: AWSCredentials.region,
            bucketName: AWSCredentials.bucketName
        )
    }
    
    func fetchAvailableVideos(completion: @escaping (Result<[Video], Error>) -> Void) {
        print("\n=== 📱 Fetching Available S3 Videos ===")
        
        s3Service.listObjects { [weak self] result in
            switch result {
            case .success(let videos):
                print("\n📹 Found \(videos.count) videos in S3:")
                videos.forEach { video in
                    print("✅ Video: \(video.displayTitle)")
                    print("   Path: \(video.remoteVideoPath)")
                }
                completion(.success(videos))
                
            case .failure(let error):
                print("❌ Failed to fetch videos: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
    
    func generateSignedRequest(for video: Video) -> URLRequest {
        guard let remoteURL = video.remoteVideoURL else {
            fatalError("Attempted to generate signed request for video without remote URL: \(video.displayTitle)")
        }
        return s3Service.generateSignedRequest(for: remoteURL)
    }
    
    func getThumbnailURL(for uuid: String) -> URL? {
        return s3Service.getThumbnailURL(for: uuid)
    }
}

// S3Service implementation
class S3Service {
    private let accessKey: String
    private let secretKey: String
    private let region: String
    private let bucketName: String
    
    init(accessKey: String, secretKey: String, region: String, bucketName: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.bucketName = bucketName
    }
    
    func listObjects(completion: @escaping (Result<[Video], Error>) -> Void) {
        let timestamp = getCurrentAWSTimestamp()
        let amzDate = timestamp.amzDate
        let dateStamp = timestamp.dateStamp
        
        let host = "\(bucketName).s3.\(region).amazonaws.com"
        let endpoint = "https://\(host)/"
        
        // Create the signed request
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        
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
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(sha256(canonicalRequest))
        """
        
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        let authorizationHeader = """
        \(algorithm) \
        Credential=\(accessKey)/\(credentialScope), \
        SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
        Signature=\(signature)
        """
        
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "S3Service", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }
            
            let parser = XMLParser(data: data)
            let delegate = S3ParserDelegate(bucketName: self.bucketName, region: self.region)
            parser.delegate = delegate
            
            if parser.parse() {
                completion(.success(delegate.videos))
            } else {
                completion(.failure(NSError(domain: "S3Service", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML response"])))
            }
        }
        
        task.resume()
    }
    
    func generateSignedRequest(for url: URL) -> URLRequest {
        let host = "\(bucketName).s3.\(region).amazonaws.com"
        let timestamp = getCurrentAWSTimestamp()
        let amzDate = timestamp.amzDate
        let dateStamp = timestamp.dateStamp
        
        // Get the URI-encoded path component
        let path = url.path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("UNSIGNED-PAYLOAD", forHTTPHeaderField: "x-amz-content-sha256")
        
        let canonicalRequest = [
            "GET",
            encodedPath,
            "",
            "host:\(host)",
            "x-amz-content-sha256:UNSIGNED-PAYLOAD",
            "x-amz-date:\(amzDate)",
            "",
            "host;x-amz-content-sha256;x-amz-date",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = """
        \(algorithm)
        \(amzDate)
        \(credentialScope)
        \(sha256(canonicalRequest))
        """
        
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).hexEncodedString()
        
        let authorizationHeader = "\(algorithm) " +
            "Credential=\(accessKey)/\(credentialScope)," +
            "SignedHeaders=host;x-amz-content-sha256;x-amz-date," +
            "Signature=\(signature)"
        
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }
    
    private func getCurrentAWSTimestamp() -> (amzDate: String, dateStamp: String) {
        let currentDate = Date()
        
        let amzDateFormatter = ISO8601DateFormatter()
        amzDateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        amzDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzDateFormatter.string(from: currentDate)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: currentDate)
        
        return (amzDate, dateStamp)
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
    
    func getThumbnailURL(for uuid: String) -> URL? {
        let urlString = "https://\(bucketName).s3.\(region).amazonaws.com/\(uuid)_thumbnail.jpg"
        return URL(string: urlString)
    }
}

// S3ParserDelegate implementation
private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var videos: [Video] = []
    
    // Add currentElement to track XML parsing
    private var currentElement: String = ""
    private var currentKey: String = ""
    private var currentMetadata: [String: String] = [:]
    private var isInMetadata = false
    
    init(bucketName: String, region: String) {
        self.bucketName = bucketName
        self.region = region
        super.init()
    }
    
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
                
                let baseUrl = "https://\(bucketName).s3.\(region).amazonaws.com"
                let videoUrlString = "\(baseUrl)/\(currentKey)"
                let thumbnailUrlString = "\(baseUrl)/\(currentKey)_thumbnail.jpg"
                
                // Create Video with all required parameters
                let video = Video(
                    id: "remote-\(currentKey.replacingOccurrences(of: ".mp4", with: "").replacingOccurrences(of: ".mov", with: ""))",
                    displayTitle: displayTitle,
                    geozone: geozone,
                    remoteVideoPath: currentKey,
                    remoteThumbnailPath: "\(currentKey)_thumbnail.jpg",
                    localVideoPath: nil,
                    isSelected: false
                )
                videos.append(video)
                
                print("📼 Parsed video: \(displayTitle)")
                print("   Video URL: \(videoUrlString)")
                print("   Thumbnail URL: \(thumbnailUrlString)")
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

private extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
} 
