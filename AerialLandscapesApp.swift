private class S3ParserDelegate: NSObject, XMLParserDelegate {
    private let bucketName: String
    private let region: String
    var videos: [Video] = []
    
    init(bucketName: String, region: String) {
        self.bucketName = bucketName
        self.region = region
    }
    
    // Temporary storage during parsing
    private var currentKey: String = ""
    private var currentDisplayTitle: String?
    private var currentGeozone: String?
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName == "Key" {
            currentKey = ""
            currentDisplayTitle = nil
            currentGeozone = nil
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch parser.currentElementName {
        case "Key": currentKey += string
        case "display-title": currentDisplayTitle = string
        case "geozone": currentGeozone = string
        default: break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Contents",
           let displayTitle = currentDisplayTitle,
           let geozone = currentGeozone,
           currentKey.hasSuffix(".mp4") || currentKey.hasSuffix(".mov") {
            
            let video = Video(
                uuid: UUID().uuidString,
                displayTitle: displayTitle,
                geozone: geozone,
                remoteVideoPath: currentKey,
                remoteThumbnailPath: "\(currentKey)_thumbnail.jpg",
                localVideoPath: nil,
                isSelected: false
            )
            videos.append(video)
        }
    }
} 