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
    @State private var isMenuVisible = false
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            // Video Player
            VideoPlayerView(player: videoPlayerModel.player)
                .edgesIgnoringSafeArea(.all)
                .onAppear {
                    videoPlayerModel.startPlayback()
                }
            
            // Title overlay (always visible)
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
            
            // Menu Overlay
            if isMenuVisible {
                VStack(spacing: 0) {
                    // Navigation Bar
                    NavigationBar(selectedTab: $selectedTab)
                        .padding(.top, 50)
                    
                    // Content
                    TabView(selection: $selectedTab) {
                        // Now Playing View (Empty because content is behind)
                        Color.clear
                            .tag(0)
                        
                        // More Videos View
                        MoreVideosView(videoPlayerModel: videoPlayerModel)
                            .tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation {
                            isMenuVisible = false
                        }
                    }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            withAnimation {
                isMenuVisible = true
            }
        }
        .onExitCommand {
            withAnimation {
                isMenuVisible.toggle()
            }
        }
    }
}

struct NavigationBar: View {
    @Binding var selectedTab: Int
    @FocusState private var isFocused: Bool
    
    private let tabs = ["Now Playing", "More Videos"]
    
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button(action: {
                        withAnimation {
                            selectedTab = index
                        }
                    }) {
                        Text(tabs[index])
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 140, height: 32)
                            .background(selectedTab == index ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(Capsule())
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onMoveCommand { direction in
                switch direction {
                case .left where selectedTab > 0:
                    withAnimation { selectedTab -= 1 }
                case .right where selectedTab < tabs.count - 1:
                    withAnimation { selectedTab += 1 }
                default:
                    break
                }
            }
            Spacer()
        }
        .padding(.top, 40)
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
}
