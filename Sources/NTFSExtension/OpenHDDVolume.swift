import Foundation
import FSKit
import Darwin

private func roError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)) }
private func fsError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

final class OpenHDDItem: FSItem {
    let inode: UInt64
    let parent: UInt64
    init(inode: UInt64, parent: UInt64) {
        self.inode = inode
        self.parent = parent
        super.init()
    }
}

private final class DirectoryCollector {
    var entries: [(String, OHNTFSItem)] = []
}

private func collectDirectoryEntry(_ opaque: UnsafeMutableRawPointer?,
                                   _ name: UnsafePointer<CChar>?,
                                   _ item: UnsafePointer<OHNTFSItem>?) -> Int32 {
    guard let opaque, let name, let item else { return EINVAL }
    let collector = Unmanaged<DirectoryCollector>.fromOpaque(opaque).takeUnretainedValue()
    collector.entries.append((String(cString: name), item.pointee))
    return 0
}

final class OpenHDDVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private(set) var handle: OpaquePointer?
    let reader: NTFSBlockReader
    let warnings: UInt32
    private let root = OpenHDDItem(inode: 5, parent: 5)

    init(handle: OpaquePointer, reader: NTFSBlockReader, warnings: UInt32) {
        self.handle = handle
        self.reader = reader
        self.warnings = warnings
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "NTFS"))
    }

    deinit {
        if let handle { oh_ntfs_close(handle) }
    }

    var maximumLinkCount: Int { Int(UInt16.max) }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let result = FSVolume.SupportedCapabilities()
        result.supports2TBFiles = true
        result.supportsSparseFiles = true
        result.supports64BitObjectIDs = true
        result.caseFormat = .insensitiveCasePreserving
        result.doesNotSupportSettingFilePermissions = true
        result.doesNotSupportVolumeSizes = true
        return result
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "openhdd_ntfs")
        result.blockSize = Int(reader.sectorSize)
        result.ioSize = 65_536
        result.totalBytes = reader.deviceSize
        result.freeBytes = 0
        result.availableBytes = 0
        return result
    }

    func activate(options: FSTaskOptions,
                  replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        guard let handle else { reply(nil, fsError(ENODEV)); return }
        var item = OHNTFSItem()
        let result = oh_ntfs_stat(handle, 5, &item)
        reply(result == 0 && item.kind == 2 ? root : nil,
              result == 0 && item.kind == 2 ? nil : fsError(result == 0 ? EIO : Int32(result)))
    }

    func deactivate(options: FSDeactivateOptions,
                    replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        // macOS 15.4 lacks requestedMountOptions. Our mount helper always uses -r.
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) { reply() }
    func synchronize(flags: FSSyncFlags,
                     replyHandler reply: @escaping (Error?) -> Void) { reply(nil) }
    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    private func attributes(_ item: OHNTFSItem, parent: UInt64) -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = item.kind == 2 ? .directory : .file
        result.mode = item.kind == 2 ? 0o555 : 0o444
        result.uid = UInt32(getuid())
        result.gid = UInt32(getgid())
        result.linkCount = item.hard_link_count
        result.size = item.size
        result.allocSize = item.allocated_size
        result.fileID = FSItem.Identifier(item.inode + 3)
        result.parentID = FSItem.Identifier(parent + 3)
        result.birthTime = timespec(tv_sec: Int(item.created_ns / 1_000_000_000),
                                    tv_nsec: Int(item.created_ns % 1_000_000_000))
        result.modifyTime = timespec(tv_sec: Int(item.modified_ns / 1_000_000_000),
                                     tv_nsec: Int(item.modified_ns % 1_000_000_000))
        return result
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let directory = directory as? OpenHDDItem,
              let name = name.string, !name.isEmpty,
              let handle else { reply(nil, nil, fsError(EINVAL)); return }
        var found = OHNTFSItem()
        let status = name.withCString { oh_ntfs_lookup(handle, directory.inode, $0, &found) }
        guard status == 0 else { reply(nil, nil, fsError(Int32(status))); return }
        reply(OpenHDDItem(inode: found.inode, parent: directory.inode),
              FSFileName(string: name), nil)
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let item = item as? OpenHDDItem, let handle else {
            reply(nil, fsError(EINVAL)); return
        }
        var found = OHNTFSItem()
        let status = oh_ntfs_stat(handle, item.inode, &found)
        reply(status == 0 ? attributes(found, parent: item.parent) : nil,
              status == 0 ? nil : fsError(Int32(status)))
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes desired: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        guard let directory = directory as? OpenHDDItem, let handle else {
            reply(FSDirectoryVerifier(rawValue: 0), fsError(EINVAL)); return
        }
        let collector = DirectoryCollector()
        let opaque = Unmanaged.passUnretained(collector).toOpaque()
        let status = oh_ntfs_list(handle, directory.inode, collectDirectoryEntry, opaque)
        guard status == 0 else {
            reply(FSDirectoryVerifier(rawValue: 0), fsError(Int32(status))); return
        }
        var entries = collector.entries
        if desired == nil {
            var current = OHNTFSItem()
            current.inode = directory.inode
            current.kind = 2
            var parent = OHNTFSItem()
            parent.inode = directory.parent
            parent.kind = 2
            entries.insert(("..", parent), at: 0)
            entries.insert((".", current), at: 0)
        }
        guard cookie.rawValue <= UInt64(Int.max) else {
            reply(FSDirectoryVerifier(rawValue: 0), fsError(EINVAL)); return
        }
        let start = cookie == .initial ? 0 : Int(cookie.rawValue)
        guard start <= entries.count else {
            reply(FSDirectoryVerifier(rawValue: 0), fsError(EINVAL)); return
        }
        for index in start..<entries.count {
            let (name, item) = entries[index]
            let packed = packer.packEntry(
                name: FSFileName(string: name),
                itemType: item.kind == 2 ? .directory : .file,
                itemID: FSItem.Identifier(item.inode + 3),
                nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                attributes: desired == nil ? nil : attributes(item, parent: directory.inode))
            if !packed { break }
        }
        reply(FSDirectoryVerifier(rawValue: 1), nil)
    }

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, Error?) -> Void) {
        guard let item = item as? OpenHDDItem, let handle,
              offset >= 0, length >= 0 else { reply(0, fsError(EINVAL)); return }
        if length == 0 { reply(0, nil); return }
        var result: Int64 = -1
        var bufferTooSmall = false
        buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress, length <= bytes.count else {
                bufferTooSmall = true
                return
            }
            result = oh_ntfs_read(handle, item.inode, UInt64(offset), base, UInt64(length))
        }
        if bufferTooSmall { reply(0, fsError(EINVAL)); return }
        reply(result >= 0 ? Int(result) : 0, result >= 0 ? nil : fsError(errno))
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, Error?) -> Void) {
        reply(0, roError())
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType,
                    inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        reply(nil, nil, roError())
    }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest, linkContents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        reply(nil, nil, roError())
    }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, roError())
    }
    func renameItem(_ item: FSItem, inDirectory source: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destination: FSItem,
                    overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, roError())
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping (Error?) -> Void) { reply(roError()) }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        reply(nil, roError())
    }
    func readSymbolicLink(_ item: FSItem,
                          replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, fsError(ENOTSUP))
    }
}
