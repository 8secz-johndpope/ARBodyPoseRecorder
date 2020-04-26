//
//  ARRecorder.swift
//  ARRecorder
//
//  Created by wxh on 2019/1/18.
//  Copyright © 2019 realibox. All rights reserved.
//

import ARKit
import AVFoundation

@available(iOS 11.0, *)
open class ARRecorder: NSObject {
    enum Status {
        case unKnown
        case ready
        case recording
        case complete
    }

    var assetWriter: ARAssetWriter?
    var captureSession: AVCaptureSession?
    var recorderQueue: DispatchQueue = DispatchQueue(label: "com.recorder.video.queue")

    var _displayLink: CADisplayLink?
    var displayLink: CADisplayLink {
        if _displayLink == nil {
            _displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
            _displayLink!.preferredFramesPerSecond = 30
        }
        return _displayLink!
    }
    var bufferSize: CGSize
    var renderer: SCNRenderer = SCNRenderer(device: nil, options: nil)

    var status: Status = .unKnown
    var isRecording: Bool = false

    var sessionPreset: AVCaptureSession.Preset {
        return AVCaptureSession.Preset.high
    }

    override init() {
        let width = UIScreen.main.bounds.size.width
        let height = UIScreen.main.bounds.size.height
        let scale: CGFloat = 1

        self.bufferSize = CGSize(width: width * scale, height: height * scale)

        super.init()
    }

    func setupSession() throws {
        self.captureSession = AVCaptureSession()
        self.captureSession?.sessionPreset = self.sessionPreset
        self.captureSession?.usesApplicationAudioSession = true
        self.captureSession?.automaticallyConfiguresApplicationAudioSession = false

        do {
            try self.setupSessionInputs()
            self.setupSessionOutputs()
            self.status = .ready
        } catch {
            throw error
        }
    }
    func startSession() {
        self.recorderQueue.async { [weak self] in
            do {
                try self?.setupAudioSession()
                if !(self?.captureSession?.isRunning ?? false) {
                    self?.captureSession?.startRunning()
                }
            } catch {
                print("\(error.localizedDescription)")
            }
        }
    }
    func stopSession() {
        self.recorderQueue.async { [weak self] in
            if self?.captureSession?.isRunning ?? false {
               self?.captureSession?.stopRunning()
            }
        }
    }
    func startRecording(_ scnView: ARSCNView) {
        self.recorderQueue.async {
            if self.status == .unKnown {
                do {
                    try self.setupSession()

                } catch {
                    print(error.localizedDescription)
                }
            }
        }
        self.recorderQueue.async {
            self.startSession()
            if self.status == .ready || self.status == .complete {
                self.status = .recording
                self.renderer.scene = scnView.scene
                self.assetWriter?.startWriting()
            }
        }
    }
    func stopRecording(finished: @escaping FinishedHandler) {
        if self.status == .recording {
            self.status = .complete
            self.displayLink.invalidate()
            _displayLink = nil
            self.renderer.scene = nil

            self.stopSession()
            self.assetWriter?.stopWriting(finished)
        }
    }

    func setupSessionInputs() throws {
        let audioDevice = AVCaptureDevice.default(for: AVMediaType.audio)!
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)

            if self.captureSession?.canAddInput(audioInput) ?? false {
                self.captureSession?.addInput(audioInput)
            } else {
                print("capture session failed to add audio input")
            }
        } catch {
            throw error
        }
    }
    func setupSessionOutputs() {
        let audioDataOutput = AVCaptureAudioDataOutput()
        audioDataOutput.setSampleBufferDelegate(self, queue: self.recorderQueue)

        if self.captureSession?.canAddOutput(audioDataOutput) ?? false {
            self.captureSession?.addOutput(audioDataOutput)
        } else {
            print("capture session failed to add audio output.")
        }

        let videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264,
                             AVVideoWidthKey: self.bufferSize.width,
                             AVVideoHeightKey: self.bufferSize.height] as [String: Any]

        let audioSettings = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: AVFileType.mp4) as! [String: Any]

        self.assetWriter = ARAssetWriter(videoSettings: videoSettings,
                                         audioSettings: audioSettings,
                                         dispatchQueue: self.recorderQueue)
    }

    func setupAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                         mode: AVAudioSession.Mode.videoRecording,
                                         options: [AVAudioSession.CategoryOptions.mixWithOthers,
                                                  AVAudioSession.CategoryOptions.allowBluetooth,
                                                  AVAudioSession.CategoryOptions.defaultToSpeaker,
                                                  AVAudioSession.CategoryOptions.interruptSpokenAudioAndMixWithOthers])
            try audioSession.setActive(true)
        } catch {
            throw error
        }
    }

    @objc func renderFrame() {
        if self.status == .recording && self.isRecording {
            self.recorderQueue.async {[weak self] in
                if self?.assetWriter?.isWriting ?? false {
                    autoreleasepool {
                        let buffer = self!.createCapturePixelBuffer()
                        self?.assetWriter?.appendPixelBuffer(buffer)
                    }
                }
            }
        }
    }
    func createCapturePixelBuffer() -> CVPixelBuffer {
        let time = CACurrentMediaTime()
        let image = self.renderer.snapshot(atTime: time, with: self.bufferSize, antialiasingMode: SCNAntialiasingMode.multisampling4X)

        let pixelBufferPointer: UnsafeMutablePointer<CVPixelBuffer?> = UnsafeMutablePointer<CVPixelBuffer?>.allocate(capacity: 1)
        CVPixelBufferPoolCreatePixelBuffer(nil, self.assetWriter!.pixelBufferAdaptor!.pixelBufferPool!, pixelBufferPointer)

        //或者
//        let dict = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
//                    kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue]
//        let cfDict = dict as CFDictionary
//        CVPixelBufferCreate(kCFAllocatorDefault, Int(self.bufferSize.width), Int(self.bufferSize.height), kCVPixelFormatType_32BGRA, cfDict, pixelBufferPointer)

        let pixelBuffer = pixelBufferPointer.pointee!
        pixelBufferPointer.deinitialize(count: 1)
        pixelBufferPointer.deallocate()

        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let data = CVPixelBufferGetBaseAddress(pixelBuffer)
        let context = CGContext(data: data,
                                width: Int(self.bufferSize.width),
                                height: Int(self.bufferSize.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        context?.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: self.bufferSize.width, height: self.bufferSize.height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return pixelBuffer
    }
}
@available(iOS 11.0, *)
extension ARRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        if self.status == .recording && _displayLink == nil {
//            self.displayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
//        }
        if self.status == .recording {
            self.isRecording = true
        } else {
            self.isRecording = false
        }
        self.assetWriter?.appendSampleBuffer(sampleBuffer)
    }
}
