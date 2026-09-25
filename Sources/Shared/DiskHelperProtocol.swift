import Foundation
import DiskArbitration
import IOKit

@objc protocol DiskHelperProtocol {
    func perform(_ operation: String, bsdName: String, mediaIdentity: String,
                 size: NSNumber, reply: @escaping (Int32, String) -> Void)
}

enum DiskIdentity {
    static let serviceName = "it.openhdd.app.helper"
    static let plistName = "it.openhdd.app.helper.plist"

    static func uuid(_ value: Any?) -> String {
        if let uuid = value as? UUID { return uuid.uuidString.lowercased() }
        if let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = value as! CFUUID
            return (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String).lowercased()
        }
        return ""
    }

    static func isPartitionName(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }

    static func identity(_ disk: DADisk, description: [String: Any]) -> String {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return "" }
        defer { IOObjectRelease(media) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS,
              registryID != 0 else { return "" }
        let uuidValue = description[kDADiskDescriptionMediaUUIDKey as String]
        return "\(registryID):\(uuid(uuidValue))"
    }
}
