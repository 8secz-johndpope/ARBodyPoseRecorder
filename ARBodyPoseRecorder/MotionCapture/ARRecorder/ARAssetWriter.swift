//
//  ARAssetWriter.swift
//  ARRecorder
//
//  Created by wxh on 2019/1/18.
//  Copyright © 2019 realibox. All rights reserved.
//

import UIKit
import AVFoundation

public typealias FinishedHandler = (_ filePath: URL) -> Void

class ARAssetWriter: NSObject {
    var isWriting = false
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    var writer: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?

    var videoSettings: [String: Any]
    var audioSettings: [String: Any]
    var writerQueue: DispatchQueue

    private var _outpuURL: URL?
    var outputURL: URL {
        get {
            if _outpuURL == nil {
                let date = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "yyMMddHHmmss"
                let string = formatter.string(from: date)

                let fileName = "\(string).mp4"
                var path = NSTemporaryDirectory()
                path.append(contentsOf: fileName)
                _outpuURL = URL(fileURLWithPath: path)
            }
            return _outpuURL!
        }
    }

    var isFirstSample = true

    init(videoSettings: [String: Any], audioSettings: [String: Any], dispatchQueue: DispatchQueue) {
        self.videoSettings = videoSettings
        self.audioSettings = audioSettings
        self.writerQueue = dispatchQueue
        super.init()
    }

    func startWriting() {
        if self.isWriting {
            return
        }

        self.writerQueue.async { [weak self] in
            self?._outpuURL = nil
            do {
                self?.writer = try AVAssetWriter(outputURL: self!.outputURL, fileType: AVFileType.mp4)
            } catch {
                print("Could not create AVAssetWriter: \(error.localizedDescription)")
            }

            self?.writer?.shouldOptimizeForNetworkUse = true
            let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: self?.videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let width = self?.videoSettings[AVVideoWidthKey] ?? 0
            let height = self?.videoSettings[AVVideoHeightKey] ?? 0

            let attributes = [kCVPixelBufferPixelFormatTypeKey : kCVPixelFormatType_32BGRA,
                              kCVPixelBufferWidthKey: width,
                              kCVPixelBufferHeightKey: height]

            self?.videoInput = videoInput
            self?.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes as [String: Any])

            if self?.writer?.canAdd(videoInput) ?? false {
                self?.writer?.add(videoInput)
            } else {
                print("Unable to add video input.")
            }

            let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: self?.audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            if self?.writer?.canAdd(audioInput) ?? false {
                self?.writer?.add(audioInput)
            } else {
                print("Unable to add audio input.")
            }
            self?.audioInput = audioInput
            self?.isWriting = true
            self?.isFirstSample = true

            if !(self?.writer?.startWriting() ?? false) {
                print("Failed to start writing")
            }
        }
    }
    func stopWriting(_ completion: @escaping FinishedHandler) {
        if self.isWriting {
            self.isWriting = false

            self.writerQueue.async {[weak self] in
                self?.writer?.finishWriting(completionHandler: {
                    if self?.writer?.status == AVAssetWriter.Status.completed {
                        completion(self!.writer!.outputURL)
                    } else {
                        print("Failed to write movie: \(self?.writer?.error?.localizedDescription ?? "")")
                    }
                })
            }
        }
    }

    func appendPixelBuffer(_ buffer: CVPixelBuffer) {
        if !self.isWriting {
            return
        }
        let time = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000)

        if self.isFirstSample {
            self.writer?.startSession(atSourceTime: time)
            self.isFirstSample = false
        }

        if self.videoInput?.isReadyForMoreMediaData ?? false {
            if !self.pixelBufferAdaptor!.append(buffer, withPresentationTime: time) {
                print("Error appending pixel buffer.")
            }
        }
    }
    func appendSampleBuffer(_ buffer: CMSampleBuffer) {
        if !self.isWriting {
            return
        }
        let formatDesc = CMSampleBufferGetFormatDescription(buffer)!
        let mediaType = CMFormatDescriptionGetMediaType(formatDesc)

        if !self.isFirstSample && mediaType == kCMMediaType_Audio {
            if self.audioInput!.isReadyForMoreMediaData {
                if !self.audioInput!.append(buffer) {
                    print("Error appending audio sample buffer.")
                }
            }
        }
    }
}
