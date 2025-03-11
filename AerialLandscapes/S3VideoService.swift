import Foundation
import CommonCrypto

class S3VideoService: ObservableObject {
    private let s3Service: S3Service
    @Published var remoteVideos: [VideoPlayerModel.VideoItem] = []
    
    init() {
        self.s3Service = S3Service(
            accessKey: AWSCredentials.accessKey,
            secretKey: AWSCredentials.secretKey,
            region: AWSCredentials.region,
            bucketName: AWSCredentials.bucketName
        )
    }
    
    func fetchAvailableVideos() {
        print("=== Starting S3 Bucket List Operation ===")
        print("Bucket: \(s3Service.bucketName)")
        print("Region: \(s3Service.region)")
        
        s3Service.listObjects { [weak self] urls in
            if let urls = urls {
                print("\n✅ Successfully retrieved \(urls.count) objects from S3")
                
                // Process only video files
                let videoURLs = urls.filter { url in
                    let lowercasePath = url.lastPathComponent.lowercased()
                    return lowercasePath.hasSuffix(".mp4") || lowercasePath.hasSuffix(".mov")
                }
                print("\nFound \(videoURLs.count) video files:")
                videoURLs.forEach { print("📹 \($0.lastPathComponent)") }
                
                // Convert URLs to VideoItems
                let videos = videoURLs.map { url in
                    let title = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "+", with: " ")
                    
                    // Determine section based on title
                    let section = self?.determineSection(title) ?? "California"
                    
                    return VideoPlayerModel.VideoItem(
                        url: url,
                        title: title,
                        isLocal: false,
                        thumbnailURL: nil,
                        section: section
                    )
                }
                
                // Update on main thread
                DispatchQueue.main.async {
                    self?.remoteVideos = videos
                    print("Found \(videos.count) videos in S3 bucket")
                    videos.forEach { print("- \($0.title) (\($0.section))") }
                }
            } else {
                print("❌ Failed to retrieve objects from S3")
            }
        }
    }
    
    private func determineSection(_ title: String) -> String {
        // Add California locations here
        let californiaKeywords = [
            "San Francisco", "Embarcadero", "Fort Funston", "Marin", "Stanford",
            "Salt Flats", "Sather", "Alabama Hills", "Northern Marin"
        ]
        
        return californiaKeywords.contains { title.contains($0) } ? "California" : "International"
    }
}

// S3Service implementation
private struct S3Service {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucketName: String
    
    func listObjects(completion: @escaping ([URL]?) -> Void) {
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
            
            if let data = data, let xmlString = String(data: data, encoding: .utf8) {
                print("📄 Response data:")
                print(xmlString)
                
                // Parse the XML response
                let parser = XMLParser(data: data)
                let delegate = S3ParserDelegate(bucketName: self.bucketName, region: self.region)
                parser.delegate = delegate
                parser.parse()
                
                print("Found objects:")
                delegate.objectURLs.forEach { print("- \($0)") }
                completion(delegate.objectURLs)
            } else {
                print("❌ No data received")
                completion(nil)
            }
        }
        
        task.resume()
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

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

// S3ParserDelegate implementation
private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var objectURLs: [URL] = []
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
                objectURLs.append(url)
            }
        }
        if elementName == currentElement {
            currentElement = nil
        }
    }
} 
