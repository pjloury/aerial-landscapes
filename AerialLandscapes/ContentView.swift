//
//  ContentView.swift
//  aerial-landscapes
//
//  Created by PJ Loury on 12/30/24.
//

import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var videoPlayerModel = VideoPlayerModel()
    @State private var selectedTab: Tab = .watchNow
    
    enum Tab {
        case watchNow
        case browse
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NowPlayingView(videoPlayerModel: videoPlayerModel)
                .tag(Tab.watchNow)
                .tabItem {
                    Label("Now Playing", systemImage: "play.circle.fill")
                }
            
            MoreVideosView(videoPlayerModel: videoPlayerModel)
                .tag(Tab.browse)
                .tabItem {
                    Label("More Videos", systemImage: "square.grid.2x2.fill")
                }
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    
    var body: some View {
        ZStack {
            // Video Player
            VideoPlayerView(player: videoPlayerModel.player)
                .edgesIgnoringSafeArea(.all)
            
            // Show message when no videos are selected
            if videoPlayerModel.selectedPlaylist.isEmpty {
                Text("Head to More Videos to get started")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
            }
            
            // Title overlay (only show when video is playing)
            if !videoPlayerModel.selectedPlaylist.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(videoPlayerModel.currentVideoTitle)
                            .font(.system(.callout, design: .default))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
                            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                            .padding(.leading, 60)
                            .padding(.bottom, 60)
                        Spacer()
                    }
                }
            }
        }
    }
}

// Custom VideoPlayerView that wraps AVPlayerViewController
struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false // Hide transport controls
        controller.videoGravity = .resizeAspectFill
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update if needed
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.light)
}
