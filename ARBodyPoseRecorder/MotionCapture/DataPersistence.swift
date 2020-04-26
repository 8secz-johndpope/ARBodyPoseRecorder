//
//  DataPersistance.swift
//  Clew
//
//  Created by Khang Vu on 3/14/19.
//  Copyright © 2019 OccamLab. All rights reserved.
//

import Foundation
import ARKit
import VectorMath

extension NSString {
    /// the URL associated in the document directory associated with the particular NSString (note: this is non-sensical for some NSStrings).
    var documentURL: URL {
        return FileManager().urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(self as String)
    }
}

class DataPersistence {

    static let shared = DataPersistence()
    /// The list of routes.  This should not be modified directly to avoid divergence of this object from the data that is stored persistently.
    var routes = [SavedRoute]()
    var capturedAnchorDataArray = [StashedAnchors]()
    var documentData: AnchorDocumentData?

    func addAnchors(anchors: [ARAnchor], lastProcessedFrameTime: TimeInterval) {

        let saved = StashedAnchors(id: "single use", name: "single use", anchors: anchors, dateCreated: Date() as NSDate, deltaTime: lastProcessedFrameTime)
        capturedAnchorDataArray.append(saved)
        print("Adding frame....")

    }

    func retrieveBodyAnchors() throws {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first

        /// set temporary path as name of route
        /// will then later be sent via the share menu
        if let path = documents?.appendingPathComponent("test.crd") {
            print("attempting unarchive")
            // if anything goes wrong with the unarchiving, stick with an emptly list of routes
            let data = try Data(contentsOf: path)
            if let document = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? AnchorDocumentData {
                print("we retrieved:", document)
                //return document
                self.documentData = document
                self.capturedAnchorDataArray = document.anchorFrameSequence
            }
        }
    }

    func archiveBodyAnchors()throws {

        /// fetch the documents directory where apple stores temporary files
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first

        /// set temporary path as name of route
        /// will then later be sent via the share menu
        if let path = documents?.appendingPathComponent("test.crd") {

            /// encode our route data before writing to disk
            print("saving anchors:", self.capturedAnchorDataArray)
            print("count:", self.capturedAnchorDataArray.count)
            let anchordDocument = AnchorDocumentData(anchorFrameSequence: self.capturedAnchorDataArray, map: nil)
            let codedData = try! NSKeyedArchiver.archivedData(withRootObject: anchordDocument, requiringSecureCoding: true)

            /// write route to file
            /// and return the path of the created temp file
            do {
                try codedData.write(to: path as URL)
                print("ok!")
                //                return path
            } catch {
                print(error.localizedDescription)
                //                return nil
            }
        }

    }

    init() {
        do {
            // if anything goes wrong with the unarchiving, stick with an emptly list of routes
            let data = try Data(contentsOf: getRoutesURL())
            if let routes = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [SavedRoute] {
                self.routes = routes
            }
        } catch {
            print("couldn't unarchive saved routes")
        }
    }

    /// Save the specified route with the optional ARWorldMap.  The variable class attribute routes will automatically be updated by this function.
    ///
    /// - Parameters:
    ///   - route: the route to save
    ///   - worldMap: an optional ARWorldMap to associate with the route
    /// - Throws: an error if the route could not be saved
    func archive(route: SavedRoute, worldMap: ARWorldMap?) throws {
        // Save route to the route list
        if !update(route: route) {
            self.routes.append(route)
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: self.routes, requiringSecureCoding: true)
        try data.write(to: self.getRoutesURL(), options: [.atomic])
        // Save the world map corresponding to the route
        if let worldMap = worldMap {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try data.write(to: self.getWorldMapURL(id: route.id as String), options: [.atomic])
        }
    }

    /// handler for importing routes from an external temporary file
    /// called in the case of a route being shared from the UIActivityViewController
    /// library
    /// TODO: Does this need to be a static function?
    func importData(from url: URL) {
        var documentData: RouteDocumentData

        /// attempt to fetch data from temporary import from external source
        do {
            print("attempting unarchive")
            // if anything goes wrong with the unarchiving, stick with an emptly list of routes
            let data = try Data(contentsOf: url)
            if let document = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? RouteDocumentData {
                documentData = document

                /// save into the route storage
                print("name of import route:", documentData.route.name)

                do {
                    try archive(route: documentData.route, worldMap: documentData.map)
                } catch {
                    print("failed to archive import route")
                }

                if let beginNote = documentData.beginVoiceNote {
                    let voiceData = Data(base64Encoded: beginNote)
                    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let path = documentData.route.beginRouteAnchorPoint.voiceNote! as String
                    let url = documentsDirectory.appendingPathComponent(path)
                    do {
                        try voiceData?.write(to: url)
                    } catch {
                        print("couldn't write file")
                    }
                }

                if let endNote = documentData.endVoiceNote {
                    let voiceData = Data(base64Encoded: endNote)
                    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let path = documentData.route.endRouteAnchorPoint.voiceNote! as String
                    let url = documentsDirectory.appendingPathComponent(path)
                    do {
                        try voiceData?.write(to: url)
                    } catch {
                        print("couldn't write file")
                    }
                }
            }
        } catch {
            print("couldn't unarchive route document")
        }

        /// remove from temp storage the file gets automatically placed into
        /// otherwise the file sticks there and won't be deleted automatically,
        /// causing app bloat.
        try? FileManager.default.removeItem(at: url)
    }

    /// handler for exporting routes to a external temporary file
    /// called in the case of a route being shared from the UIActivityViewController
    /// library
    func exportToURL(route: SavedRoute) -> URL? {
        /// fetch the world map if it exists. Otherwise, value is nil
        let worldMap = self.unarchiveMap(id: route.id as String)

        /// paths to the beginning and ending landmark files
        var beginVoiceFile: String?
        var endVoiceFile: String?

        /// fetch begginning voice notefile if it exists
        if let beginVoiceURL = route.beginRouteAnchorPoint.voiceNote {
            /// build a full valid path the found url from the landmark
            let voiceurl = beginVoiceURL.documentURL

            /// encode audio file into a base64 string to be written to
            /// a shareable file
            if let data = try? Data(contentsOf: voiceurl) {
                beginVoiceFile = data.base64EncodedString()
            }
        }

        /// fetch beginning voice notefile if it exists
        if let endVoiceURL = route.endRouteAnchorPoint.voiceNote {
            /// build a full valid path the found url from the landmark
            let voiceurl = endVoiceURL.documentURL

            /// encode audio file into a base64 string to be written to
            /// a shareable file
            if let data = try? Data(contentsOf: voiceurl) {
                endVoiceFile = data.base64EncodedString()
            }
        }

        /// TODO: need to fix to include functionality for phones which don't support
        /// world maps (> iOS 12)
        let routeData = RouteDocumentData(route: route,
                                          map: worldMap,
                                          beginVoiceNote: beginVoiceFile,
                                          endVoiceNote: endVoiceFile)

        /// fetch the documents directory where apple stores temporary files
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first

        /// set temporary path as name of route
        /// will then later be sent via the share menu
        guard let path = documents?.appendingPathComponent("/\(route.name).crd") else {
            return nil
        }

        /// encode our route data before writing to disk
        let codedData = try! NSKeyedArchiver.archivedData(withRootObject: routeData, requiringSecureCoding: true)

        /// write route to file
        /// and return the path of the created temp file
        do {
            try codedData.write(to: path as URL)
            return path
        } catch {
            print(error.localizedDescription)
            return nil
        }
    }

    /// Load the map from the app's local storage.  If we are on a platform that doesn't support ARWorldMap, this function always returns nil
    ///
    /// - Parameter id: the map id to fetch
    /// - Returns: the stored map
    func unarchiveMap(id: String) -> ARWorldMap? {
        do {
            let data = try Data(contentsOf: getWorldMapURL(id: id))
            guard let unarchivedObject = ((try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)) as ARWorldMap??),
                let worldMap = unarchivedObject else { return nil }
            return worldMap
        } catch {
            print("Error retrieving world map data.")
            return nil
        }
    }

    /// Update the specified route.
    ///
    /// - Parameter route: the route to update
    /// - Returns: true if the route was updated successfully, false if the route could not be found in the routes list
    func update(route: SavedRoute) -> Bool {
        /// Updates the route in the list based on matching ids.  The return value is true if the route was found and updates and false otherwise from the route list
        if let indexOfRoute = routes.firstIndex(where: { $0.id == route.id || $0.name == route.name }) {
            routes[indexOfRoute] = route
            return true
        }
        return false
    }

    /// Delete the specified route
    ///
    /// - Parameter route: the route do delete
    /// - Throws: an error if deletion cannot be performed
    func delete(route: SavedRoute) throws {
        // Remove route from the route list
        self.routes = self.routes.filter { $0.id != route.id }
        let data = try NSKeyedArchiver.archivedData(withRootObject: self.routes, requiringSecureCoding: true)
        try data.write(to: self.getRoutesURL(), options: [.atomic])
        // Remove the world map corresponding to the route.  We use try? to continue execution even if this fails, since it is not strictly necessary for continued operation
        try? FileManager().removeItem(atPath: self.getWorldMapURL(id: route.id as String).path)
        if let beginRouteAnchorPointVoiceNote = route.beginRouteAnchorPoint.voiceNote {
            try? FileManager().removeItem(at: beginRouteAnchorPointVoiceNote.documentURL)
        }
        if let endRouteAnchorPointVoiceNote = route.endRouteAnchorPoint.voiceNote {
            try? FileManager().removeItem(at: endRouteAnchorPointVoiceNote.documentURL)
        }
    }

    /// A utility method to map a file name into a URL in the app's document directory.
    ///
    /// - Parameter filename: the filename that should be converted to a URL
    /// - Returns: A URL to the filename within the document directory of the app
    private func getURL(filename: String) -> URL {
        return FileManager().urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(filename)
    }

    /// Returns the URL used to persist the ARWorldMap corresponding to the specified route id.
    ///
    /// - Parameter id: the id of the route
    /// - Returns: the URL used to store the ARWorldMap for the route
    private func getWorldMapURL(id: String) -> URL {
        return getURL(filename: id)
    }

    /// Returns URL at which to store the file that contains the routes.  The ARWorldMap object are stored elsewhere.
    ///
    /// - Returns: the URL of the routes file
    private func getRoutesURL() -> URL {
        return getURL(filename: "routeList")
    }

}

/// Struct to store location and transform information
///
/// Contains:
/// * `location` (`LocationInfo`)
/// * `transformMatrix` (`Matrix3` from `VectorMath`)
/// TODO: this is a bit confusing as to what the transformMatrix does that the transform stored with `location` doesn't do.
public struct CurrentCoordinateInfo {
    /// the location of the coordinate info
    public var location: LocationInfo
    /// the 3x3 transform matrix
    public var transformMatrix: Matrix3 = Matrix3.identity

    /// Initialize a `CurrentCoordinateInfoObject`
    ///
    /// - Parameters:
    ///   - location: the location to use
    ///   - transMatrix: the transformation matrix to use
    public init(_ location: LocationInfo, transMatrix: Matrix3) {
        self.location = location
        self.transformMatrix = transMatrix
    }

    /// Initialize a `CurrentCoordinatedInfoObject`.  This assumes the identity matrix as the transform.
    ///
    /// - Parameter location: the location to use
    public init(_ location: LocationInfo) {
        self.location = location
    }
}

/// Struct to store position information and yaw.  By sub-classing `ARAnchor`, we get specify the 6-DOFs of an ARAnchor while getting the ability to support the secure coding protocol for free.
public class LocationInfo: ARAnchor {

    /// This initializes a new `LocationInfo` object based on the specified `ARAnchor`.
    ///
    /// - Parameter anchor: the `ARAnchor` to use for describing the location
    required init(anchor: ARAnchor) {
        super.init(anchor: anchor)
    }

    /// This initializes a new `LocationInfo` object based on the specified transform.
    ///
    /// TODO: I think we might be able to delete this since all it does is call the super class method.
    /// - Parameter transform: the transform (4x4 matrix) describing the location
    override init(transform: simd_float4x4) {
        super.init(transform: transform)
    }

    /// indicates whether secure coding is supported (it is)
    override public class var supportsSecureCoding: Bool {
        return true
    }

    /// The function required by NSSecureCoding protocol to decode the object
    ///
    /// - Parameter aDecoder: the NSCoder doing the decoding
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// The function required by NSSecureCoding protocol to encode the object
    /// TODO: I think we might be able to delete this since all it does is call the super class method.
    ///
    /// - Parameter aCoder: the NSCoder doing the encoding
    override public func encode(with aCoder: NSCoder) {
        super.encode(with: aCoder)
    }

}

extension ARAnchor {
    /// the translation expressed as a 3-element vector (x, y, z)
    public var translation: SCNVector3 {
        let translation = self.transform.columns.3
        return SCNVector3(translation.x, translation.y, translation.z)
    }

    /// the Euler angles as a 3 element vector (pitch, yaw, roll)
    public var eulerAngles: SCNVector3 {
        get {
            // first we get the quaternion from m00...m22
            // see http://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/index.htm
            let qw = sqrt(1 + self.transform.columns.0.x + self.transform.columns.1.y + self.transform.columns.2.z) / 2.0
            let qx = (self.transform.columns.2.y - self.transform.columns.1.z) / (qw * 4.0)
            let qy = (self.transform.columns.0.z - self.transform.columns.2.x) / (qw * 4.0)
            let qz = (self.transform.columns.1.x - self.transform.columns.0.y) / (qw * 4.0)

            // then we deduce euler angles with some cosines
            // see https://en.wikipedia.org/wiki/Conversion_between_quaternions_and_Euler_angles
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

            return SCNVector3(pitch, yaw, roll)
        }
    }

    /// the x translation
    public var x: Float {
        return translation.x
    }

    /// the y translation
    public var y: Float {
        return translation.y
    }

    /// the z translation
    public var z: Float {
        return translation.z
    }

    /// the yaw (in radians)
    public var yaw: Float {
        return eulerAngles.y
    }
}

/// Struct to store position and orientation of a keypoint
///
/// Contains:
/// * `location` (`LocationInfo`)
/// * `orientation` (`Vector3` from `VectorMath`)
public struct KeypointInfo {
    /// the location of the keypoint
    public var location: LocationInfo
    /// the orientation of a keypoint is a unit vector that points from the previous keypoint to current keypoint.  The orientation is useful for defining the area where we check off the user as having reached a keypoint
    public var orientation: VectorMath.Vector3
}

/// An encapsulation of a route Anchor Point, including position, text, and audio information.
class RouteAnchorPoint: NSObject, NSSecureCoding {
    /// Needs to be declared and assigned true to support `NSSecureCoding`
    static var supportsSecureCoding = true

    /// The position and orientation as a 4x4 matrix
    public var transform: simd_float4x4?
    /// Text to help user remember the Anchor Point
    public var information: NSString?
    /// The URL to an audio file that contains information to help the user remember a Anchor Point
    public var voiceNote: NSString?

    /// Initialize the Anchor Point.
    ///
    /// - Parameters:
    ///   - transform: the position and orientation
    ///   - information: textual description
    ///   - voiceNote: URL to auditory description
    public init(transform: simd_float4x4? = nil, information: NSString? = nil, voiceNote: NSString? = nil) {
        self.transform = transform
        self.information = information
        self.voiceNote = voiceNote
    }

    /// Encode the Anchor Point.
    ///
    /// - Parameter aCoder: the encoder
    func encode(with aCoder: NSCoder) {
        if transform != nil {
            aCoder.encode(ARAnchor(transform: transform!), forKey: "transformAsARAnchor")
        }
        aCoder.encode(information, forKey: "information")
        aCoder.encode(voiceNote, forKey: "voiceNote")
    }

    /// Decode the Anchor Point.
    ///
    /// - Parameter aDecoder: the decoder
    required convenience init?(coder aDecoder: NSCoder) {
        var transform: simd_float4x4? = nil
        var information: NSString? = nil
        var voiceNote: NSString? = nil

        if let transformAsARAnchor = aDecoder.decodeObject(of: ARAnchor.self, forKey: "transformAsARAnchor") {
            transform = transformAsARAnchor.transform
        }
        information = aDecoder.decodeObject(of: NSString.self, forKey: "information")
        voiceNote = aDecoder.decodeObject(of: NSString.self, forKey: "voiceNote")
        self.init(transform: transform, information: information, voiceNote: voiceNote)
    }

}

/// [Deprecated] [Needed to load old routes] An encapsulation of a route landmark, including position, text, and audio information.
class RouteLandmark: NSObject, NSSecureCoding {
    /// Needs to be declared and assigned true to support `NSSecureCoding`
    static var supportsSecureCoding = true

    /// The position and orientation as a 4x4 matrix
    public var transform: simd_float4x4?
    /// Text to help user remember the landmark
    public var information: NSString?
    /// The URL to an audio file that contains information to help the user remember a landmark
    public var voiceNote: NSString?

    /// Initialize the landmark.
    ///
    /// - Parameters:
    ///   - transform: the position and orientation
    ///   - information: textual description
    ///   - voiceNote: URL to auditory description
    public init(transform: simd_float4x4? = nil, information: NSString? = nil, voiceNote: NSString? = nil) {
        self.transform = transform
        self.information = information
        self.voiceNote = voiceNote
    }

    /// Encode the landmark.
    ///
    /// - Parameter aCoder: the encoder
    func encode(with aCoder: NSCoder) {
        if transform != nil {
            aCoder.encode(ARAnchor(transform: transform!), forKey: "transformAsARAnchor")
        }
        aCoder.encode(information, forKey: "information")
        aCoder.encode(voiceNote, forKey: "voiceNote")
    }

    /// Decode the landmark.
    ///
    /// - Parameter aDecoder: the decoder
    required convenience init?(coder aDecoder: NSCoder) {
        var transform: simd_float4x4? = nil
        var information: NSString? = nil
        var voiceNote: NSString? = nil

        if let transformAsARAnchor = aDecoder.decodeObject(of: ARAnchor.self, forKey: "transformAsARAnchor") {
            transform = transformAsARAnchor.transform
        }
        information = aDecoder.decodeObject(of: NSString.self, forKey: "information")
        voiceNote = aDecoder.decodeObject(of: NSString.self, forKey: "voiceNote")
        self.init(transform: transform, information: information, voiceNote: voiceNote)
    }

}

/// This class encapsulates a route that can be persisted to storage and reloaded as needed.
class SavedRoute: NSObject, NSSecureCoding {
    /// This is needed to use NSSecureCoding
    static var supportsSecureCoding = true

    /// The id of the route (should be unique)
    public var id: NSString
    /// The name of the route (as displayed by the `RoutesViewController`)
    public var name: NSString
    /// The date the route was recorded
    public var dateCreated: NSDate
    /// The crumbs that make up the route.  The densely sampled positions (crumbs) are stored and the keypoints (sparser goal positionsare calculated on demand when navigation is requested.
    public var crumbs: [LocationInfo]
    /// The Anchor Point marks the beginning of the route (needed for start to end navigation)
    public var beginRouteAnchorPoint: RouteAnchorPoint
    /// The Anchor Point marks the end of the route (needed for end to start navigation)
    public var endRouteAnchorPoint: RouteAnchorPoint

    /// Initialize the route.
    ///
    /// - Parameters:
    ///   - id: the route id
    ///   - name: the route name
    ///   - crumbs: the crumbs for the route
    ///   - dateCreated: the route creation date
    ///   - beginRouteAnchorPoint: the Anchor Point for the beginning of the route (pass a `RouteAnchorPoint` with default initialization if no Anchor Point was recorded at the beginning of the route)
    ///   - endRouteAnchorPoint: the Anchor Point for the end of the route (pass a `RouteAnchorPoint` with default initialization if no Anchor Point was recorded at the end of the route)
    public init(id: NSString, name: NSString, crumbs: [LocationInfo], dateCreated: NSDate = NSDate(), beginRouteAnchorPoint: RouteAnchorPoint, endRouteAnchorPoint: RouteAnchorPoint) {
        self.id = id
        self.name = name
        self.crumbs = crumbs
        self.dateCreated = dateCreated
        self.beginRouteAnchorPoint = beginRouteAnchorPoint
        self.endRouteAnchorPoint = endRouteAnchorPoint
    }

    /// Encodes the object to the specified coder object
    ///
    /// - Parameter aCoder: the object used for encoding
    func encode(with aCoder: NSCoder) {
        aCoder.encode(id, forKey: "id")
        aCoder.encode(name, forKey: "name")
        aCoder.encode(crumbs, forKey: "crumbs")
        aCoder.encode(dateCreated, forKey: "dateCreated")
        aCoder.encode(beginRouteAnchorPoint, forKey: "beginRouteAnchorPoint")
        aCoder.encode(endRouteAnchorPoint, forKey: "endRouteAnchorPoint")
    }

    /// Initialize an object based using data from a decoder
    ///
    /// - Parameter aDecoder: the decoder object
    required convenience init?(coder aDecoder: NSCoder) {
        guard let id = aDecoder.decodeObject(of: NSString.self, forKey: "id") else {
            return nil
        }
        guard let name = aDecoder.decodeObject(of: NSString.self, forKey: "name") else {
            return nil
        }
        guard let crumbs = aDecoder.decodeObject(of: [].self, forKey: "crumbs") as? [LocationInfo] else {
            return nil
        }
        guard let dateCreated = aDecoder.decodeObject(of: NSDate.self, forKey: "dateCreated") else {
            return nil
        }

        let beginRouteAnchorPoint: RouteAnchorPoint
        if let anchorPoint = aDecoder.decodeObject(of: RouteAnchorPoint.self, forKey: "beginRouteAnchorPoint") {
            beginRouteAnchorPoint = anchorPoint
        } else {
            // check to see if we have a route in the old format
            guard let beginRouteLandmark = aDecoder.decodeObject(of: RouteLandmark.self, forKey: "beginRouteLandmark") else {
                return nil
            }
            // convert to the new format
            beginRouteAnchorPoint = RouteAnchorPoint(transform: beginRouteLandmark.transform, information: beginRouteLandmark.information, voiceNote: beginRouteLandmark.voiceNote)
        }
        let endRouteAnchorPoint: RouteAnchorPoint

        if let anchorPoint = aDecoder.decodeObject(of: RouteAnchorPoint.self, forKey: "endRouteAnchorPoint") {
            endRouteAnchorPoint = anchorPoint
        } else {
            // check to see if we have a route in the old format
            guard let endRouteLandmark = aDecoder.decodeObject(of: RouteLandmark.self, forKey: "endRouteLandmark") else {
                return nil
            }
            // convert to the new format
            endRouteAnchorPoint = RouteAnchorPoint(transform: endRouteLandmark.transform, information: endRouteLandmark.information, voiceNote: endRouteLandmark.voiceNote)
        }

        self.init(id: id, name: name, crumbs: crumbs, dateCreated: dateCreated, beginRouteAnchorPoint: beginRouteAnchorPoint, endRouteAnchorPoint: endRouteAnchorPoint)
    }
}

/// This class encapsulates a route that can be persisted to storage and reloaded as needed.
class StashedAnchors: NSObject, NSSecureCoding {
    /// This is needed to use NSSecureCoding
    static var supportsSecureCoding = true

    /// The id of the route (should be unique)
    public var id: NSString
    /// The name of the route (as displayed by the `RoutesViewController`)
    public var name: NSString
    /// The date the route was recorded
    public var dateCreated: NSDate
    public var deltaTime: TimeInterval
    /// The crumbs that make up the route.  The densely sampled positions (crumbs) are stored and the keypoints (sparser goal positionsare calculated on demand when navigation is requested.
    public var anchors: [ARAnchor]
    //    /// The Anchor Point marks the beginning of the route (needed for start to end navigation)
    //    public var beginRouteAnchorPoint: RouteAnchorPoint
    //    /// The Anchor Point marks the end of the route (needed for end to start navigation)
    //    public var endRouteAnchorPoint: RouteAnchorPoint

    /// Initialize the route.
    ///
    /// - Parameters:
    ///   - id: the route id
    ///   - name: the route name
    ///   - crumbs: the crumbs for the route
    ///   - dateCreated: the route creation date
    ///   - beginRouteAnchorPoint: the Anchor Point for the beginning of the route (pass a `RouteAnchorPoint` with default initialization if no Anchor Point was recorded at the beginning of the route)
    ///   - endRouteAnchorPoint: the Anchor Point for the end of the route (pass a `RouteAnchorPoint` with default initialization if no Anchor Point was recorded at the end of the route)
    public init(id: NSString, name: NSString, anchors: [ARAnchor], dateCreated: NSDate = NSDate(), deltaTime: TimeInterval = TimeInterval() ) {
        self.id = id
        self.name = name
        self.anchors = anchors
        self.dateCreated = dateCreated
        self.deltaTime = deltaTime

    }

    /// Encodes the object to the specified coder object
    ///
    /// - Parameter aCoder: the object used for encoding
    func encode(with aCoder: NSCoder) {
        aCoder.encode(id, forKey: "id")
        aCoder.encode(name, forKey: "name")
        aCoder.encode(anchors, forKey: "anchors")
        aCoder.encode(dateCreated, forKey: "dateCreated")
    }

    /// Initialize an object based using data from a decoder
    ///
    /// - Parameter aDecoder: the decoder object
    required convenience init?(coder aDecoder: NSCoder) {
        guard let id = aDecoder.decodeObject(of: NSString.self, forKey: "id") else {
            return nil
        }
        guard let name = aDecoder.decodeObject(of: NSString.self, forKey: "name") else {
            return nil
        }
        guard let anchors = aDecoder.decodeObject(of: [].self, forKey: "anchors") as? [ARAnchor] else {
            return nil
        }
        guard let dateCreated = aDecoder.decodeObject(of: NSDate.self, forKey: "dateCreated") else {
            return nil
        }

        self.init(id: id, name: name, anchors: anchors, dateCreated: dateCreated)
    }
}
/// Pathfinder class calculates turns or "keypoints" given a path array of LocationInfo
class PathFinder {

    ///  Maximum width of the breadcrumb path.
    ///
    /// Points falling outside this margin will produce more keypoints, through Ramer-Douglas-Peucker algorithm
    ///
    /// - TODO: Clarify units
    private let pathWidth: Scalar!

    /// The crumbs that make up the desired path. These should be ordered with respect to the user's intended direction of travel (start to end versus end to start)
    private var crumbs: [LocationInfo]

    /// Initializes the PathFinder class and determines the value of `pathWidth`
    ///
    /// - Parameters:
    ///   - crumbs: a list of `LocationInfo` objects representing the trail of breadcrumbs left on the path
    ///   - hapticFeedback: whether or not hapticFeedback is on.
    ///   - voiceFeedBack: whether or not voiceFeedback is on.
    ///
    /// - TODO:
    ///   - Clarify why these magic `pathWidth` values are as they are.
    init(crumbs: [LocationInfo], hapticFeedback: Bool, voiceFeedback: Bool) {
        self.crumbs = crumbs
        if(!hapticFeedback && voiceFeedback) {
            pathWidth = 0.3
        } else {
            pathWidth = 0.3
        }
    }

    /// a list of `KeypointInfo` objects representing the important turns in the path.
    public var keypoints: [KeypointInfo] {
        get {
            return getKeypoints(edibleCrumbs: crumbs)
        }
    }

    /// Creates a list of keypoints in a path given a list of points dropped several times per second.
    ///
    /// - Parameter edibleCrumbs: a list of `LocationInfo` objects representing the trail of breadcrumbs left on the path.
    /// - Returns: a list of `KeypointInfo` objects representing the turns in the path
    func getKeypoints(edibleCrumbs: [LocationInfo]) -> [KeypointInfo] {
        var keypoints = [KeypointInfo]()
        let firstKeypointLocation = edibleCrumbs.first!
        let firstKeypointOrientation = Vector3.x
        keypoints.append(KeypointInfo(location: firstKeypointLocation, orientation: firstKeypointOrientation))

        keypoints += calculateKeypoints(edibleCrumbs: edibleCrumbs)

        let lastKeypointLocation = edibleCrumbs.last!
        let lastKeypointOrientation = Vector3(_: [(keypoints.last?.location.x)! - edibleCrumbs.last!.x,
                                                  0,
                                                  (keypoints.last?.location.z)! - edibleCrumbs.last!.z]).normalized()
        keypoints.append(KeypointInfo(location: lastKeypointLocation, orientation: lastKeypointOrientation))
        return keypoints
    }

    /// Recursively simplifies a path of points using Ramer-Douglas-Peucker algorithm.
    ///
    /// - Parameter edibleCrumbs: a list of `LocationInfo` objects representing the trail of breadcrumbs left on the path.
    /// - Returns: a list of `KeypointInfo` objects representing the important turns in the path.
    func calculateKeypoints(edibleCrumbs: [LocationInfo]) -> [KeypointInfo] {
        var keypoints = [KeypointInfo]()

        let firstCrumb = edibleCrumbs.first
        let lastCrumb = edibleCrumbs.last

        //  Direction vector of last crumb in list relative to first
        let pointVector = Vector3.init(_: [(lastCrumb?.x)! - (firstCrumb?.x)!,
                                           (lastCrumb?.y)! - (firstCrumb?.y)!,
                                           (lastCrumb?.z)! - (firstCrumb?.z)!])

        //  Vector normal to pointVector, rotated 90 degrees about vertical axis
        let normalVector = Matrix3.init(_: [0, 0, 1,
                                            0, 0, 0,
                                            -1, 0, 0]) * pointVector

        let unitNormalVector = normalVector.normalized()
        let unitPointVector = pointVector.normalized()

        //  Third orthonormal vector to normalVector and pointVector, used to detect
        //  vertical changes like stairways
        let unitNormalVector2 = unitPointVector.cross(unitNormalVector)

        var listOfDistances = [Scalar]()

        //  Find maximum distance from the path trajectory among all points
        for crumb in edibleCrumbs {
            let c = Vector3.init([crumb.x - (firstCrumb?.x)!, crumb.y - (firstCrumb?.y)!, crumb.z - (firstCrumb?.z)!])
            let a = c.dot(unitNormalVector2)
            let b = c.dot(unitNormalVector)
            listOfDistances.append(sqrtf(powf(a, 2) + powf(b, 2)))
        }

        let maxDistance = listOfDistances.max()
        let maxIndex = listOfDistances.firstIndex(of: maxDistance!)

        //  If a point is farther from path center than parameter pathWidth,
        //  there must be another keypoint within that stretch.
        if (maxDistance! > pathWidth) {

            //  Recursively find all keypoints before the detected keypoint and
            //  after the detected keypoint, and add them in a list with the
            //  detected keypoint.
            let prevKeypoints = calculateKeypoints(edibleCrumbs: Array(edibleCrumbs[0..<(maxIndex!+1)]))
            let postKeypoints = calculateKeypoints(edibleCrumbs: Array(edibleCrumbs[maxIndex!...]))

            var prevKeypointLocation = edibleCrumbs.first!
            var prevKeypointOrientation = Vector3.x
            if (!prevKeypoints.isEmpty) {
                keypoints += prevKeypoints

                prevKeypointLocation = prevKeypoints.last!.location
                prevKeypointOrientation = prevKeypoints.last!.orientation
            }

            let prevKeypoint = KeypointInfo(location: prevKeypointLocation, orientation: prevKeypointOrientation)

            let newKeypointLocation = edibleCrumbs[maxIndex!]
            let newKeypointOrientation = Vector3(_: [prevKeypoint.location.x - newKeypointLocation.x,
                                                     0,
                                                     prevKeypoint.location.z - newKeypointLocation.z]).normalized()

            keypoints.append(KeypointInfo(location: newKeypointLocation, orientation: newKeypointOrientation))

            if (!postKeypoints.isEmpty) {
                keypoints += postKeypoints
            }
        }

        return keypoints
    }

}

/// class for handling the selection of data to be stored in UIActivityShare Menus
/// This wrapping functionality is required to that we can have all elements related
/// to a specific route stored in a single encoded file ready to be shared throughout
/// iOS
class RouteDocumentData: NSObject, NSSecureCoding {
    /// This is needed to use NSSecureCoding
    static var supportsSecureCoding = true

    /// the main route itself
    public var route: SavedRoute

    /// the world map
    public var map: ARWorldMap?

    /// first landmark audio note
    public var beginVoiceNote: String?

    /// second landmark audio note
    public var endVoiceNote: String?

    /// Initialize the sharing document.
    ///
    /// - Parameters:
    ///   - route: the route data
    ///   - map: the arkit world map
    public init(route: SavedRoute, map: ARWorldMap? = nil, beginVoiceNote: String? = nil, endVoiceNote: String? = nil) {
        self.route = route
        self.map = map
        self.beginVoiceNote = beginVoiceNote
        self.endVoiceNote = endVoiceNote
    }

    /// Encodes the object to the specified coder object. Here, we combine each essential element
    /// of a saved route to a single file, encoding each of them with a key known to clew so that we
    /// can handle decoding later.
    /// - Parameter aCoder: the object used for encoding
    func encode(with aCoder: NSCoder) {
        aCoder.encode(route, forKey: "route")
        aCoder.encode(map, forKey: "map")
        aCoder.encode(beginVoiceNote as NSString?, forKey: "beginVoiceNote")
        aCoder.encode(endVoiceNote as NSString?, forKey: "endVoiceNote")
    }

    /// Initialize an object based using data from a decoder.
    /// (Begin reconstruction of a saved route from a crd file)
    /// - Parameter aDecoder: the decoder object
    required convenience init?(coder aDecoder: NSCoder) {
        /// use a guard for decoding route as we know that it cannot be nil
        guard let route = aDecoder.decodeObject(of: SavedRoute.self, forKey: "route") else {
            return nil
        }

        /// decode map, beginning landmark voice note, and ending landmark voice note,
        /// knowing that the map may not necessarily exist

        let newMap = aDecoder.decodeObject(of: ARWorldMap.self, forKey: "map")

        let beginNote = aDecoder.decodeObject(of: NSString.self, forKey: "beginVoiceNote")
        let endNote = aDecoder.decodeObject(of: NSString.self, forKey: "endVoiceNote")

        /// construct a new saved route from the decoded data
        self.init(route: route, map: newMap, beginVoiceNote: beginNote as String?, endVoiceNote: endNote as String?)
    }
}

/// class for handling the selection of data to be stored in UIActivityShare Menus
/// This wrapping functionality is required to that we can have all elements related
/// to a specific route stored in a single encoded file ready to be shared throughout
/// iOS
class AnchorDocumentData: NSObject, NSSecureCoding {
    /// This is needed to use NSSecureCoding
    static var supportsSecureCoding = true

    /// the frames of bodyanchors
    public var anchorFrameSequence = [StashedAnchors]()
    //public var route: StashedAnchors

    /// the world map
    public var map: ARWorldMap?

    /// Initialize the sharing document.
    ///
    /// - Parameters:
    ///   - route: the route data
    ///   - map: the arkit world map
    public init(anchorFrameSequence: [StashedAnchors], map: ARWorldMap? = nil) {
        self.anchorFrameSequence = anchorFrameSequence
        self.map = map

    }

    /// Encodes the object to the specified coder object. Here, we combine each essential element
    /// of a saved route to a single file, encoding each of them with a key known to clew so that we
    /// can handle decoding later.
    /// - Parameter aCoder: the object used for encoding
    func encode(with aCoder: NSCoder) {
        aCoder.encode(anchorFrameSequence, forKey: "anchorFrameSequence")
        aCoder.encode(map, forKey: "map")
    }

    /// Initialize an object based using data from a decoder.
    /// (Begin reconstruction of a saved route from a crd file)
    /// - Parameter aDecoder: the decoder object
    required convenience init?(coder aDecoder: NSCoder) {
        /// use a guard for decoding route as we know that it cannot be nil
        guard let bodyAnchors = aDecoder.decodeObject(forKey: "anchorFrameSequence") as? [StashedAnchors] else {
            return nil
        }

        /// decode map, beginning landmark voice note, and ending landmark voice note,
        /// knowing that the map may not necessarily exist

        let newMap = aDecoder.decodeObject(of: ARWorldMap.self, forKey: "map")

        /// construct a new saved route from the decoded data
        self.init(anchorFrameSequence: bodyAnchors, map: newMap)
    }
}
