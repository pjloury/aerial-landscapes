// GenerateVideoConfig.swift

import Foundation

struct VideoConfigGenerator {
    static func generate() -> String {
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        var videos: [[String: String]] = []
        
        do {
            let items = try fileManager.contentsOfDirectory(atPath: bundlePath)
            let videoFiles = items.filter { $0.lowercased().hasSuffix(".mov") || $0.lowercased().hasSuffix(".mp4") }
            
            print("\nFound \(videoFiles.count) video files:")
            
            for filename in videoFiles {
                let displayTitle = filename
                    .replacingOccurrences(of: ".mov", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".mp4", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "Test", with: "Test ")
                
                print("Processing: \(filename) -> \(displayTitle)")
                
                let video: [String: String] = [
                    "filename": filename,
                    "display-title": displayTitle,
                    "geozone": "international" // Default value, you can edit manually
                ]
                videos.append(video)
            }
        } catch {
            print("Error reading directory: \(error)")
        }
        
        let config = ["videos": videos]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            
            // Try to save to Documents directory
            if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let configURL = documentsPath.appendingPathComponent("videos_config.json")
                try? jsonString.write(to: configURL, atomically: true, encoding: .utf8)
                print("\nSaved config to: \(configURL.path)")
            }
            
            return jsonString
        }
        
        return "{}"
    }
    
    static func run() {
        print("Generating video configuration...")
        let config = generate()
        print("\nGenerated Configuration:")
        print(config)
    }
}

// You can run this by calling:
// VideoConfigGenerator.run()