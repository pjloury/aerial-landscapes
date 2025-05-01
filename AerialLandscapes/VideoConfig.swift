struct VideoConfig {
    let videos: [VideoMetadata]
    
    static let shared = VideoConfig(videos: [
        VideoMetadata(
            uuid: "FF001",
            filename: "Fort Funston",
            displayTitle: "Fort Funston",
            geozone: "domestic"
        ),
        VideoMetadata(
            uuid: "WV001",
            filename: "Waves",
            displayTitle: "Waves",
            geozone: "domestic"
        ),
        VideoMetadata(
            uuid: "SQ001",
            filename: "Stanford Main Quad",
            displayTitle: "Stanford Main Quad",
            geozone: "domestic"
        ),
        VideoMetadata(
            uuid: "ST001",
            filename: "Sather Tower",
            displayTitle: "Sather Tower",
            geozone: "domestic"
        ),
        VideoMetadata(
            uuid: "SF001",
            filename: "Salt Flats",
            displayTitle: "Salt Flats",
            geozone: "domestic"
        ),
        VideoMetadata(
            uuid: "TA001",
            filename: "TestAlps",
            displayTitle: "Fuschl am See",
            geozone: "international"
        ),
        VideoMetadata(
            uuid: "TH001",
            filename: "TestHvar",
            displayTitle: "Hvar, Croatia",
            geozone: "international"
        ),
        VideoMetadata(
            uuid: "TC001",
            filename: "TestCopa",
            displayTitle: "Copacabana",
            geozone: "international"
        ),
        VideoMetadata(
            uuid: "TV001",
            filename: "TestValencia",
            displayTitle: "Old Town Valencia",
            geozone: "international"
        )
    ])
}

struct VideoMetadata {
    let uuid: String
    let filename: String
    let displayTitle: String
    let geozone: String
} 
