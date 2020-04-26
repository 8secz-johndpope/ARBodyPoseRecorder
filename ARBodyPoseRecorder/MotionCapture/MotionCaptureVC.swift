import Foundation
import AVFoundation
import UIKit
import RealityKit
import ARKit
import Combine
import MessageUI
import ReplayKit
import Combine
import SnapKit

let frameRate = 1.0 / 24
var startingPos = [Float]()

var audioFilename: URL?


protocol RecordingButtonDelegate {
    func didStartCapture()
    func didEndCapture()
}

@objcMembers
class RecordingButton: UIButton {

    func defaultState() {
            self.setImage(#imageLiteral(resourceName: "recordButton"), for: .normal)
    }

    var isRecordingState: Bool = false
    func record() {
        isRecordingState = true
        self.setImage(#imageLiteral(resourceName: "stopRecording"), for: .normal)

    }

    func stopRecord() {
        isRecordingState = false
        self.setImage(#imageLiteral(resourceName: "recordButton"), for: .normal)
    }

}

@objcMembers
class PlayButton: UIButton {

    func defaultState() {
            self.setImage(#imageLiteral(resourceName: "tabChallenge"), for: .normal)
    }

    var isPlayingState: Bool = false
    func play() {
        isPlayingState = true
        self.setImage(#imageLiteral(resourceName: "glasses_shutter_yellow_thumbnail"), for: .normal)

    }

    func stopRecord() {
        isPlayingState = false
        self.setImage(#imageLiteral(resourceName: "tabChallenge"), for: .normal)
    }

}

//https://michael-martinez.fr/arkit-transform-matrices-quaternions-and-related-conversions/
extension Array where Element: Equatable {

    // Remove first collection element that is equal to the given `object`:
    mutating func removeObject(_ object: Element) {
        guard let index = firstIndex(of: object) else { return }
        remove(at: index)
    }

}

class MyArView: RealityKit.ARView {

}

extension MotionCaptureVC: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {

    }
}

class MotionCaptureVC: UIViewController, RPPreviewViewControllerDelegate {
    private var c: Cancellable?

    lazy var arRecorder: ARRecorder = {
        let recorder = ARRecorder()
        return recorder
    }()
    var logger = Logger()
    let poseKit = PoseKit()

    var allAnchors: [[ARAnchor]] = []

    var arView = MyArView(frame: .zero)
    let recordButton = RecordingButton()

    let playButton = PlayButton()
    var loadCaptureButton = RoundedButton()
    var togglePeopleButton = RoundedButton()

    var recording = false

    var playerItem: AVPlayerItem?
    var player: AVPlayer?

    // The 3D character to display.
    var character: BodyTrackedEntity?
    let characterOffset: SIMD3<Float> = [0, 0, 0] // [-1.0, 0, 0]Offset the character by one meter to the left
    let characterAnchor = AnchorEntity()

    // Playback character
    var playbackCharacter: BodyTrackedEntity?
    var playbackCharacterOffset: SIMD3<Float> =  [0.0, 0, 0]//Offset the character by one meter to the left
    var playbackCharacterAnchor = AnchorEntity()

    let recorder = RPScreenRecorder.shared()

    var playAudio = false
    var isCapturePlay = false

    var lastProcessedFrameTime = TimeInterval()

    var screenRecord = false

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.addSubview(arView)

        arView.debugOptions = [ARView.DebugOptions.showAnchorGeometry, ARView.DebugOptions.showAnchorOrigins, ARView.DebugOptions.showFeaturePoints, ARView.DebugOptions.showStatistics, ARView.DebugOptions.showWorldOrigin]

        arView.snp.remakeConstraints { (make) in
            make.top.left.width.height.equalToSuperview()
        }

        c = arView.scene.subscribe(to: SceneEvents.Update.self) { (_) in

            if self.recording {
//                print("recording anchors...")
                if let frame = self.arView.session.currentFrame {
                    if let body = frame.detectedBody {
//                       print("detectedBody:", frame.detectedBody)
                      //   MyPlayer.playBeep()
//                        if (frame.timestamp - self.lastProcessedFrameTime) >= (1 / Double(self.frameRate)) {
                            self.lastProcessedFrameTime = frame.timestamp
                            DataPersistence.shared.addAnchors(anchors: frame.anchors, lastProcessedFrameTime: frame.timestamp)
//                            self.arRecorder.renderFrame() needs -   func startRecording(_ scnView: ARSCNView) {

//                        }
                    }

                }
                self.loadCaptureButton.isEnabled = true

            }

        }

    }

    override func viewDidAppear(_ animated: Bool) {
        UIApplication.shared.isIdleTimerDisabled = true

        super.viewDidAppear(animated)
        arView.session.delegate = self

        guard ARBodyTrackingConfiguration.isSupported else {
            fatalError("This feature is only supported on devices with an A12 chip")
        }

        // Run a body tracking configration.
        let configuration = ARBodyTrackingConfiguration()
        configuration.frameSemantics = .bodyDetection
        arView.session.run(configuration)

        arView.scene.addAnchor(characterAnchor)

        arView.scene.addAnchor(playbackCharacterAnchor)

        // Asynchronously load the 3D character.
        var cancellable: AnyCancellable? = nil
        cancellable = Entity.loadBodyTrackedAsync(named: "character/robot").sink(
            receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("Error: Unable to load model: \(error.localizedDescription)")
                }
                cancellable?.cancel()
        }, receiveValue: { (character: Entity) in
            if let character = character as? BodyTrackedEntity {
                // Scale the character to human size
                character.scale = [1.0, 1.0, 1.0]
                self.character = character

                self.playbackCharacter = character.clone(recursive: true)
                self.playbackCharacter?.scale = [1.0, 1.0, 1.0]
                cancellable?.cancel()
            } else {
                print("Error: Unable to load model as BodyTrackedEntity")
            }
        })

        // Proof Of concept - Restore a saved body anchors
        // TODO - design this better

        do {
                          try DataPersistence.shared.retrieveBodyAnchors()
                          print("ok!")
                          //                return path
                      } catch {
                          print(error.localizedDescription)

                      }

        buildUI()

    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        terminate()
    }

    func terminate() {
        arView.session.pause()
        arView.removeFromSuperview()
        //       arSCNView = nil
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        print("Session failed. Changing worldAlignment property.")
        print(error.localizedDescription)

    }

    // Captured da playing frame
    var frameIndex: Int = 0
    // play frames at time intervals
    var capturePlayTimer: Timer?

    // crudely places character in center of screen.
    func playCapturedAnimation() {
        // reset any playing animation
        self.isCapturePlay = false
        capturePlayTimer?.invalidate()
        self.frameIndex = 0

        //shrink existing character as sanity check so were looking at the other character
        self.character?.scale = [0.5, 0.5, 0.5]

        self.playbackCharacter?.scale = [1, 1, 1]

        // TODO - review ARKIT and use their logic to position items - https://github.com/ignacio-chiazzo/ARKit/
//        let screenCentre: CGPoint = CGPoint(x: self.arView.bounds.midX, y: self.arView.bounds.midY)
//
//        let arHitTestResults: [ARHitTestResult] = self.arView.hitTest(screenCentre, types: [.featurePoint])
//
//        if let closestResult = arHitTestResults.first {
//            // Get Coordinates of HitTest
//            let transform: matrix_float4x4 = closestResult.worldTransform
//
//            // Set up some properties
//            self.playbackCharacter?.position = simd_make_float3(transform.columns.3)
//        }

        isCapturePlay = true
        capturePlayTimer?.invalidate()
        capturePlayTimer = Timer.scheduledTimer(timeInterval: 0.30, target: self, selector: #selector(playFrame), userInfo: nil, repeats: true)
    }

    @objc func playFrame() {

        print("playFrame...")
        if self.frameIndex < DataPersistence.shared.capturedAnchorDataArray.count {
            let bodyAnchors = DataPersistence.shared.capturedAnchorDataArray[self.frameIndex]

            // let frame = bodyAnchors.anchors[0] // there's more here

            for anchor in bodyAnchors.anchors {
                 print("anchor:", anchor)
                guard let bodyAnchor = anchor as? ARBodyAnchor else {
                    print("no bodyAnchor detected...:", anchor)
                    continue

                }

                self.playCapturedFrame(capturedData: bodyAnchor)
                self.frameIndex += 1
            }
        }
        else {
           self.isCapturePlay = false
            capturePlayTimer!.invalidate()
            print("playFrame - end")
        }
    }

    func playCapturedFrame(capturedData anchor: ARBodyAnchor) {
        //        for anchor in capturedData {
        // Update the position of the character anchor's position.
        let bodyPosition = simd_make_float3(anchor.transform.columns.3)

        playbackCharacterAnchor.position = bodyPosition + playbackCharacterOffset
        // Also copy over the rotation of the body anchor, because the skeleton's pose
        // in the world is relative to the body anchor's rotation.
        playbackCharacterAnchor.orientation = Transform(matrix: anchor.transform).rotation

        if let playbackCharacter = playbackCharacter, playbackCharacter.parent == nil {
            // Attach the character to its anchor as soon as
            // 1. the body anchor was detected and
            // 2. the character was loaded.
            playbackCharacterAnchor.addChild(playbackCharacter)
        }
    }

//    var time = CACurrentMediaTime()
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {

        if isCapturePlay { return }
        for anchor in anchors {
            guard let bodyAnchor = anchor as? ARBodyAnchor else { continue }

            // Update the position of the character anchor's position.
            let bodyPosition = simd_make_float3(bodyAnchor.transform.columns.3)
            characterAnchor.position = bodyPosition + characterOffset
            // Also copy over the rotation of the body anchor, because the skeleton's pose
            // in the world is relative to the body anchor's rotation.
            characterAnchor.orientation = Transform(matrix: bodyAnchor.transform).rotation

            print(poseKit.BodyTrackingPosition(bodyAnchor: bodyAnchor))
            if let character = character, character.parent == nil {
                // Attach the character to its anchor as soon as
                // 1. the body anchor was detected and
                // 2. the character was loaded.
                characterAnchor.addChild(character)

            }

        }

        playbackCharacterAnchor = characterAnchor.clone(recursive: true)
    }

    @IBAction func Back(_ sender: UIButton) {
        NotificationCenter.default.post(name: Notification.Name(rawValue: "setUpCap"), object: nil)

        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func click(_ sender: UIButton) {

    }

    @objc func playerDidFinishPlaying(sender: Notification) {

        // self.buttonsRecord.layer.removeAllAnimations()
        //  self.buttonsRecord.alpha = 1

        //   buttonsRecord.setTitle("stop", for: .normal)
        //   buttonsRecord.backgroundColor = UIColor.red
        recording = true

        if let url = audioFilename {
            if  playAudio {
                playerItem = AVPlayerItem(url: url)
                NotificationCenter.default.addObserver(self, selector: #selector(self.playerDidFinishPlayingRecorded(sender:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: playerItem)

                player = AVPlayer(playerItem: playerItem!)
                player?.volume = 30
                player!.play()

            }
        }

    }

    @objc func playerDidFinishPlayingRecorded(sender: Notification) {
        recording = false
        stopScreenRecording()
    }

    func stopScreenRecording() {

        if recorder.isRecording == false {
            //    sendEmail()
        }

        recorder.stopRecording { [unowned self] (preview, _) in

            if let unwrappedPreview = preview {
                unwrappedPreview.previewControllerDelegate = self
                self.present(unwrappedPreview, animated: true)
            }

        }

    }

    func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        dismiss(animated: true)
        //sendEmail()
    }

    @objc func backButtonTapped() {
//        do {
//            try DataPersistence.shared.retrieveBodyAnchors()
//            let tempAnchor = DataPersistence.shared.documentData
//            print("INFO: anchor to send to s3:", tempAnchor)
//            let documents = FileManager.default.urls(
//                for: .documentDirectory,
//                in: .userDomainMask
//            ).first
//            if let path = documents?.appendingPathComponent("test.crd") {
//                let aiPath = "\(path)".replacingOccurrences(of: "file://", with: "")
//                let aiObservable: Observable<AnyObject>  = MediaManager.uploadAIData(atPath: aiPath, disposeBag: self.rx.disposeBag, progress: { _ in })
//                let aiDisposable = aiObservable.subscribe(onNext: { (response) in
//
//                    print("INFO: ai at s3Url:", response)
//                    /* zero bytes
//                     s3Url: {
//                     PostResponse =     {
//                     Location = "https://8secondz.s3.amazonaws.com/videos%2Fbde85ac0-425b-11ea-ad2c-5b372995a2f2-.mov";
//                     };
//                     }
//                     */
//                })
//                aiDisposable.disposed(by: self.rx.disposeBag)
//            }
//
//        } catch {
//            print("INFO: unarchive retrieve anchors error:", error)
//        }
//        self.dismiss()
    }
    func addCloseButton() {

    

    }

    func buildUI() {
        self.view.addSubview(recordButton)
        recordButton.snp.makeConstraints { (make) in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-55)
            make.width.equalTo(64)
            make.height.equalTo(64)
        }
        recordButton.addTarget(self, action: #selector(recordButtonPressed(sender:)), for: .touchUpInside)
        recordButton.defaultState()

//        self.view.addSubview(playButton)
//        playButton.snp.makeConstraints { (make) in
//            make.left.equalToSuperview()
//            make.bottom.equalToSuperview().offset(-55)
//            make.width.equalTo(64)
//            make.height.equalTo(64)
//        }
//        playButton.addTarget(self, action: #selector(playButtonPressed(sender:)), for: .touchUpInside)
//        playButton.defaultState()

        self.view.addSubview(loadCaptureButton)
        loadCaptureButton.snp.makeConstraints { (make) in
         make.centerX.equalToSuperview()
         make.bottom.equalToSuperview().offset(-155)
         make.width.equalTo(200)
         make.height.equalTo(44)
        }
        loadCaptureButton.addTarget(self, action: #selector(loadCapturedAnimationPressed(sender:)), for: .touchUpInside)
        loadCaptureButton.setTitle("Playback", for: .normal)
        loadCaptureButton.isEnabled = false

//        self.view.addSubview(togglePeopleButton)
//        togglePeopleButton.snp.makeConstraints { (make) in
//         make.centerX.equalToSuperview()
//         make.bottom.equalTo(loadCaptureButton.snp.top).offset(10)
//         make.width.equalTo(200)
//         make.height.equalTo(44)
//        }
//        togglePeopleButton.addTarget(self, action: #selector(togglePeopleOcclusion), for: .touchUpInside)
//        togglePeopleButton.setTitle("Toggle Occlusion", for: .normal)

        addCloseButton()
    }

    @objc func loadCapturedAnimationPressed(sender: RoundedButton) {
        print("INFO:loadCapturedAnimationPressed")
        if (isCapturePlay) {

            self.stopCapturedAnimation()
        }else {
             print("🔥 pausing session!!!!!")
//            self.arView.session.pause()
            self.playCapturedAnimation()
        }
    }
    func stopCapturedAnimation() {
        self.isCapturePlay = false
        self.capturePlayTimer?.invalidate()
        self.frameIndex = 0
    }
    @objc func playButtonPressed(sender: PlayButton) {
        print("INFO:playButtonPressed")

    }
    @objc func recordButtonPressed(sender: RecordingButton) {
        print("INFO:recordButtonPressed")
        self.stopCapturedAnimation()

        if (recording == false) {
            recording = true
        } else {
            // here we stopped recording frames and are now saving
            recording = false
            do {
                // TODO - we are saving AREnvironmentProbeAnchor - https://developer.apple.com/documentation/arkit/arenvironmentprobeanchor that doesn't make sense.
                     try DataPersistence.shared.archiveBodyAnchors()
                     print("ok!")
                     //                return path
                 } catch {
                     print(error.localizedDescription)

                 }

        }

    }
    /// seems personSegmentationWithDepth needs ARSCNView! https://github.com/dklein42/webAndMobile-demos/blob/39977404e9991477eb9e07a3a56b06a4be1fb835/ARKit3/ARKit3/PeopleOcclusionViewController.swift

    @objc func togglePeopleOcclusion() {
        /*guard let config = arView.session.configuration as? ARWorldTrackingConfiguration else {
            fatalError("Unexpectedly failed to get the configuration.")
        }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) else {
            fatalError("People occlusion is not supported on this device.")
        }
        switch config.frameSemantics {
        case [.personSegmentationWithDepth]:
            config.frameSemantics.remove(.personSegmentationWithDepth)
            //messageLabel.displayMessage("People occlusion off", duration: 1.0)
        default:
            config.frameSemantics.insert(.personSegmentationWithDepth)
           // messageLabel.displayMessage("People occlusion on", duration: 1.0)
        }
        arView.session.run(config)*/
        let configuration = ARBodyTrackingConfiguration()
        configuration.frameSemantics = .personSegmentationWithDepth
        arView.session.run(configuration)
    }
}

class RoundedButton: UIButton {

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    func setup() {
        backgroundColor = tintColor
        layer.cornerRadius = 8
        clipsToBounds = true
        setTitleColor(.white, for: [])
        titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
    }

    override var isEnabled: Bool {
        didSet {
            backgroundColor = isEnabled ? tintColor : .gray
        }
    }

}

public extension matrix_float4x4 {

    /// Retrieve translation from a quaternion matrix
    var translation: SCNVector3 {
        get {
            return SCNVector3Make(columns.3.x, columns.3.y, columns.3.z)
        }
    }

    /// Retrieve euler angles from a quaternion matrix
    var eulerAngles: [Float] {
        get {
            //first we get the quaternion from m00...m22
            //see http://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/index.htm
            let qw = sqrt(1 + self.columns.0.x + self.columns.1.y + self.columns.2.z) / 2.0
            let qx = (self.columns.2.y - self.columns.1.z) / (qw * 4.0)
            let qy = (self.columns.0.z - self.columns.2.x) / (qw * 4.0)
            let qz = (self.columns.1.x - self.columns.0.y) / (qw * 4.0)

            //then we deduce euler angles with some cosines
            //see https://en.wikipedia.org/wiki/Conversion_between_quaternions_and_Euler_angles
            // roll (x-axis rotation)
            let sinr = +2.0 * (qw * qx + qy * qz)
            let cosr = +1.0 - 2.0 * (qx * qx + qy * qy)
            let roll = atan2(sinr, cosr)

            // pitch (y-axis rotation)
            let sinp = +2.0 * (qw * qy - qz * qx)
            var pitch: Float
            if abs(sinp) >= 1 {
                pitch = copysign(Float.pi / 2, sinp)
            } else {
                pitch = asin(sinp)
            }

            // yaw (z-axis rotation)
            let siny = +2.0 * (qw * qz + qx * qy)
            let cosy = +1.0 - 2.0 * (qy * qy + qz * qz)
            let yaw = atan2(siny, cosy)

            let angles = [pitch, yaw, roll]

            return angles
        }
    }
}

//https://michael-martinez.fr/arkit-transform-matrices-quaternions-and-related-conversions/
public extension matrix_float4x4 {

    //return [x, y, z, pitch, yaw, roll]
    var pos_eulerAngles: [Float] {
        get {
            //first we get the quaternion from m00...m22
            //see http://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/index.htm
            let qw = sqrt(1 + self.columns.0.x + self.columns.1.y + self.columns.2.z) / 2.0
            let qx = (self.columns.2.y - self.columns.1.z) / (qw * 4.0)
            let qy = (self.columns.0.z - self.columns.2.x) / (qw * 4.0)
            let qz = (self.columns.1.x - self.columns.0.y) / (qw * 4.0)

            //then we deduce euler angles with some cosines
            //see https://en.wikipedia.org/wiki/Conversion_between_quaternions_and_Euler_angles
            // roll (x-axis rotation)
            let sinr = +2.0 * (qw * qx + qy * qz)
            let cosr = +1.0 - 2.0 * (qx * qx + qy * qy)
            var roll = atan2(sinr, cosr)

            // pitch (y-axis rotation)
            let sinp = +2.0 * (qw * qy - qz * qx)
            var pitch: Float
            if abs(sinp) >= 1 {
                pitch = copysign(Float.pi / 2, sinp)
            } else {
                pitch = asin(sinp)
            }

            // yaw (z-axis rotation)
            let siny = +2.0 * (qw * qz + qx * qy)
            let cosy = +1.0 - 2.0 * (qy * qy + qz * qz)
            var yaw = atan2(siny, cosy)

            //https://stackoverflow.com/questions/45212598/convert-matrix-float4x4-to-x-y-z-space

            var x = columns.3.x
            var y = columns.3.y
            var z = columns.3.z

            if x.isNaN {
                x = 0
            }

            if y.isNaN {
                y = 0
            }

            if z.isNaN {
                z = 0
            }

            if pitch.isNaN {
                pitch = 0
            }

            if yaw.isNaN {
                yaw = 0
            }

            if roll.isNaN {
                roll = 0
            }

            return [x, y, z, pitch, yaw, roll]
        }
    }

    var pos: [Float] {
        get {

            //https://stackoverflow.com/questions/45212598/convert-matrix-float4x4-to-x-y-z-space

            var x = columns.3.x
            var y = columns.3.y
            var z = columns.3.z

            if x.isNaN {
                x = 0
            }

            if y.isNaN {
                y = 0
            }

            if z.isNaN {
                z = 0
            }

            return [x, y, z, ]
        }
    }

}
