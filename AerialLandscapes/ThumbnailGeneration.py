import os
import subprocess
import shutil
from pathlib import Path

def cleanup_thumbnails(output_dir):
    """
    Clean up existing thumbnails directory.
    
    Args:
        output_dir (Path): Directory containing thumbnails
    """
    try:
        if output_dir.exists():
            print(f"\n🗑️  Cleaning up old thumbnails directory: {output_dir}")
            shutil.rmtree(output_dir)
            print("✅ Old thumbnails removed")
    except Exception as e:
        print(f"❌ Error cleaning up thumbnails: {str(e)}")
        
def generate_thumbnail(video_path, output_dir, timestamp="00:00:05"):
    """
    Generate a thumbnail from a video file using ffmpeg.
    
    Args:
        video_path (Path): Path to the video file
        output_dir (Path): Directory to save thumbnails
        timestamp (str): Timestamp to extract frame from (default: "00:00:05")
    """
    try:
        # Create output filename
        thumbnail_name = f"{video_path.stem}_thumbnail.jpg"
        thumbnail_path = output_dir / thumbnail_name
        
        # Construct ffmpeg command
        cmd = [
            "ffmpeg",
            "-i", str(video_path),
            "-ss", timestamp,
            "-vframes", "1",
            "-vf", "scale=1920:1080",  # Scale to 1080p
            "-q:v", "2",  # High quality
            str(thumbnail_path)
        ]
        
        print(f"\nProcessing {video_path.name}...")
        subprocess.run(cmd, check=True, capture_output=True)
        print(f"✅ Generated thumbnail: {thumbnail_path}")
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Error processing {video_path.name}:")
        print(e.stderr.decode())
    except Exception as e:
        print(f"❌ Unexpected error for {video_path.name}:")
        print(str(e))

def main():
    # Set up paths
    video_dir = Path("/Users/Shared/Aerial Local/Additional Videos")
    output_dir = video_dir / "thumbnails"  # Single directory for all thumbnails
    
    # Clean up old thumbnails
    cleanup_thumbnails(output_dir)
    
    # Create fresh thumbnails directory
    output_dir.mkdir(exist_ok=True)
    
    # Get all video files
    video_files = list(video_dir.glob("*.mp4")) + list(video_dir.glob("*.mov"))
    
    if not video_files:
        print("No video files found in directory!")
        return
    
    print(f"\nFound {len(video_files)} video files")
    print(f"Saving thumbnails to: {output_dir}")
    
    # Process each video
    for video_path in video_files:
        generate_thumbnail(video_path, output_dir)
    
    print("\n✨ Thumbnail generation complete!")
    print(f"Generated {len(video_files)} thumbnails in: {output_dir}")

if __name__ == "__main__":
    main()
