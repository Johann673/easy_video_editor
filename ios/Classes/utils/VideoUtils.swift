import AVFoundation
import UIKit
import Foundation

enum VideoError: Error {
    case fileNotFound
    case invalidParameters
    case exportFailed(String)
    case thumbnailGenerationFailed
    case invalidAsset
    case invalidTimeRange
    case invalidPath
}

class VideoUtils {
    
    // MARK: - Trim Video
    static func trimVideo(videoPath: String, startTimeMs: Int64, endTimeMs: Int64) throws -> String {
        let url = URL(fileURLWithPath: videoPath)
        
        let asset = AVAsset(url: url)
        let duration = asset.duration.toMilliseconds
        
        // Validate time range
        guard startTimeMs >= 0,
              endTimeMs > startTimeMs,
              endTimeMs <= duration else {
            throw VideoError.invalidTimeRange
        }
        
        let startTime = startTimeMs.toCMTime
        let endTime = endTimeMs.toCMTime
        let timeRange = CMTimeRange(start: startTime, end: endTime)
        
        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoError.invalidAsset
        }
        
        // Generate output path
        let outputPath = NSTemporaryDirectory() + UUID().uuidString + ".mp4"
        let outputURL = URL(fileURLWithPath: outputPath)
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange
        
        // Wait for export completion
        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        
        // Check export status
        if let error = exportSession.error {
            throw VideoError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw VideoError.exportFailed("Export failed with status: \(exportSession.status.rawValue)")
        }
        
        return outputPath
    }
    
    // MARK: - Merge Videos
    static func mergeVideos(videoPaths: [String]) throws -> String {
        guard !videoPaths.isEmpty else {
            throw VideoError.invalidParameters
        }
        
        for path in videoPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw VideoError.fileNotFound
            }
        }
        
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("Failed to create composition tracks")
        }
        
        var currentTime = CMTime.zero
        
        for path in videoPaths {
            let asset = AVAsset(url: URL(fileURLWithPath: path))
            let duration = asset.duration
            
            if let videoTrack = asset.tracks(withMediaType: .video).first {
                try compositionVideoTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: videoTrack,
                    at: currentTime
                )
            }
            
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: currentTime
                )
            }
            
            currentTime = CMTimeAdd(currentTime, duration)
        }
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("merged_video_\(Date().timeIntervalSince1970).mp4")
        
        return try export(composition: composition, outputURL: outputURL)
    }
    
    // MARK: - Extract Audio
    static func extractAudio(videoPath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let composition = AVMutableComposition()
        
        guard let audioTrack = asset.tracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("Failed to get audio track")
        }
        
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: audioTrack,
            at: .zero
        )
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("extracted_audio_\(Date().timeIntervalSince1970).m4a")
        
        let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        exportSession?.outputURL = outputURL
        exportSession?.outputFileType = .m4a
        
        let semaphore = DispatchSemaphore(value: 0)
        exportSession?.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        
        guard exportSession?.status == .completed else {
            throw VideoError.exportFailed(exportSession?.error?.localizedDescription ?? "Unknown error")
        }
        
        return outputURL.path
    }
    
    // MARK: - Adjust Video Speed
    static func adjustVideoSpeed(videoPath: String, speed: Float) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        guard speed > 0 else {
            throw VideoError.invalidParameters
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let composition = AVMutableComposition()
        
        // Create tracks
        guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoTrack = asset.tracks(withMediaType: .video).first,
              let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw VideoError.invalidAsset
        }
        
        // Get original duration in milliseconds
        let originalDurationMs = asset.duration.toMilliseconds
        
        // Calculate new duration
        let scaledDurationMs = Int64(Double(originalDurationMs) / Double(speed))
        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        do {
            // Insert video and audio tracks
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            
            // Scale tracks to new duration
            compositionVideoTrack.scaleTimeRange(timeRange, toDuration: scaledDurationMs.toCMTime)
            compositionAudioTrack.scaleTimeRange(timeRange, toDuration: scaledDurationMs.toCMTime)
            
            // Export
            let outputPath = NSTemporaryDirectory() + UUID().uuidString + ".mp4"
            let outputURL = URL(fileURLWithPath: outputPath)
            
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw VideoError.invalidAsset
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            
            // Wait for export completion
            let semaphore = DispatchSemaphore(value: 0)
            exportSession.exportAsynchronously {
                semaphore.signal()
            }
            semaphore.wait()
            
            if let error = exportSession.error {
                throw VideoError.exportFailed(error.localizedDescription)
            }
            
            guard exportSession.status == .completed else {
                throw VideoError.exportFailed("Export failed with status: \(exportSession.status.rawValue)")
            }
            
            return outputPath
        } catch {
            throw VideoError.exportFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Remove Audio
    static func removeAudioFromVideo(videoPath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let composition = AVMutableComposition()
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("Failed to get video track")
        }
        
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: videoTrack,
            at: .zero
        )
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("muted_video_\(Date().timeIntervalSince1970).mp4")
        
        return try export(composition: composition, outputURL: outputURL)
    }
    
    // MARK: - Scale Video
    static func scaleVideo(videoPath: String, scaleX: Float, scaleY: Float) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        guard scaleX > 0, scaleY > 0 else {
            throw VideoError.invalidParameters
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let audioTrack = asset.tracks(withMediaType: .audio).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("Failed to get tracks")
        }
        
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: audioTrack,
            at: .zero
        )
        
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        
        videoComposition.renderSize = CGSize(
            width: naturalSize.width * CGFloat(scaleX),
            height: naturalSize.height * CGFloat(scaleY)
        )
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("scaled_video_\(Date().timeIntervalSince1970).mp4")
        
        return try export(composition: composition, outputURL: outputURL, videoComposition: videoComposition)
    }
    
    // MARK: - Rotate Video
    static func rotateVideo(videoPath: String, rotationDegrees: Float) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        guard rotationDegrees.truncatingRemainder(dividingBy: 90) == 0 else {
            throw VideoError.invalidParameters
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let audioTrack = asset.tracks(withMediaType: .audio).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("Failed to get tracks")
        }
        
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: audioTrack,
            at: .zero
        )
        
        let naturalSize = videoTrack.naturalSize
        var transform = videoTrack.preferredTransform
        
        transform = transform.rotated(by: CGFloat(rotationDegrees) * .pi / 180)
        
        let isPortrait = abs(rotationDegrees.truncatingRemainder(dividingBy: 180)) == 90
        videoComposition.renderSize = isPortrait ?
            CGSize(width: naturalSize.height, height: naturalSize.width) :
            naturalSize
        
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("rotated_video_\(Date().timeIntervalSince1970).mp4")
        
        return try export(composition: composition, outputURL: outputURL, videoComposition: videoComposition)
    }
    
    // MARK: - Generate Thumbnail
    static func generateThumbnail(videoPath: String, timeMs: Int64, quality: Int = 80) throws -> String {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw VideoError.fileNotFound
        }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // Convert milliseconds to CMTime
        let time = timeMs.toCMTime
        
        // Validate time range
        let duration = asset.duration.toMilliseconds
        guard timeMs >= 0 && timeMs <= duration else {
            throw VideoError.invalidTimeRange
        }
        
        do {
            let imageRef = try generator.copyCGImage(at: time, actualTime: nil)
            let image = UIImage(cgImage: imageRef)
            
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail_\(Date().timeIntervalSince1970).jpg")
            
            guard let data = image.jpegData(compressionQuality: CGFloat(quality) / 100),
                  (try? data.write(to: outputURL)) != nil else {
                throw VideoError.thumbnailGenerationFailed
            }
            
            return outputURL.path
        } catch {
            throw VideoError.thumbnailGenerationFailed
        }
    }
    
    // MARK: - Helper Methods
    private static func export(composition: AVComposition, outputURL: URL, videoComposition: AVVideoComposition? = nil) throws -> String {
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoError.exportFailed("Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        if let videoComposition = videoComposition {
            exportSession.videoComposition = videoComposition
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        
        guard exportSession.status == .completed else {
            throw VideoError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        }
        
        return outputURL.path
    }
}
