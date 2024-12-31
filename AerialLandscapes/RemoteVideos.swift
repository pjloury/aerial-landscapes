import Foundation

struct RemoteVideos {
    static let videos = [
        VideoPlayerModel.VideoItem(
            url: URL(string: "https://pjloury-aerial.s3.us-west-2.amazonaws.com/Alabama+Hills.mp4")!,
            title: "Alabama Hills",
            isLocal: false,
            thumbnailURL: nil
        ),
        VideoPlayerModel.VideoItem(
            url: URL(string: "https://pjloury-aerial.s3.us-west-2.amazonaws.com/NorthernMarinCoastline.mp4")!,
            title: "Northern Marin Coastline",
            isLocal: false,
            thumbnailURL: nil
        ),
        VideoPlayerModel.VideoItem(
            url: URL(string: "https://pjloury-aerial.s3.us-west-2.amazonaws.com/SF+Embarcadero.mp4")!,
            title: "San Francisco Embarcadero",
            isLocal: false,
            thumbnailURL: nil
        )
    ]
} 