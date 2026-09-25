import Foundation
import FSKit
import Darwin
import OSLog

private let integrityLog = Logger(subsystem: "it.openhdd.app.ntfs", category: "integrity")

private func auditBlockWrites() {
    integrityLog.notice("block_write_attempts=\(oh_ntfs_total_write_attempts(), privacy: .public)")
}

@main
struct OpenHDDFileSystemExtension: UnaryFileSystemExtension {
    let fileSystem = OpenHDDFileSystem()
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

/// Only this object touches FSKit's block resource. All reads are sector aligned.
final class NTFSBlockReader {
    let resource: FSBlockDeviceResource
    let sectorSize: UInt64
    let deviceSize: UInt64

    init?(_ resource: FSBlockDeviceResource) {
        let sector = max(resource.blockSize, resource.physicalBlockSize)
        guard resource.blockSize >= 512,
              resource.blockSize & (resource.blockSize - 1) == 0,
              sector >= 512, sector <= 65_536,
              sector & (sector - 1) == 0,
              resource.blockCount > 0,
              resource.blockCount <= UInt64.max / resource.blockSize,
              resource.blockCount * resource.blockSize <= UInt64(Int64.max),
              (resource.blockCount * resource.blockSize) % sector == 0 else { return nil }
        self.resource = resource
        self.sectorSize = sector
        self.deviceSize = resource.blockCount * resource.blockSize
    }

    func read(offset: UInt64, into destination: UnsafeMutableRawPointer, count: UInt64) -> Int64 {
        guard offset <= deviceSize, count <= deviceSize - offset else {
            errno = EINVAL
            return -1
        }
        if count == 0 { return 0 }
        var completed: UInt64 = 0
        while completed < count {
            let current = offset + completed
            let sectorStart = current / sectorSize * sectorSize
            let leading = current - sectorStart
            let request = min(count - completed, 1_048_576)
            let needed = leading + request
            let rounded = ((needed + sectorSize - 1) / sectorSize) * sectorSize
            guard rounded <= deviceSize - sectorStart,
                  rounded <= UInt64(Int.max) else {
                errno = EIO
                return -1
            }
            let aligned = UnsafeMutableRawPointer.allocate(byteCount: Int(rounded),
                                                            alignment: Int(sectorSize))
            defer { aligned.deallocate() }
            do {
                let n = try resource.read(
                    into: UnsafeMutableRawBufferPointer(start: aligned, count: Int(rounded)),
                    startingAt: off_t(sectorStart), length: Int(rounded))
                guard n >= Int(leading + request) else {
                    errno = EIO
                    return -1
                }
                destination.advanced(by: Int(completed))
                    .copyMemory(from: aligned.advanced(by: Int(leading)), byteCount: Int(request))
                completed += request
            } catch {
                errno = EIO
                return -1
            }
        }
        return Int64(completed)
    }
}

private func ntfsReadCallback(_ opaque: UnsafeMutableRawPointer?,
                              _ offset: UInt64,
                              _ buffer: UnsafeMutableRawPointer?,
                              _ length: UInt64) -> Int64 {
    guard let opaque, let buffer else { errno = EFAULT; return -1 }
    let reader = Unmanaged<NTFSBlockReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(offset: offset, into: buffer, count: length)
}

final class OpenHDDFileSystem: FSUnaryFileSystem,
                              FSUnaryFileSystemOperations,
                              FSManageableResourceMaintenanceOperations {
    private var loaded: OpenHDDVolume?

    private func open(_ resource: FSResource) -> (OpenHDDVolume?, NSError?) {
        guard let block = resource as? FSBlockDeviceResource,
              let reader = NTFSBlockReader(block) else {
            return (nil, posixError(EINVAL))
        }
        var handle: OpaquePointer?
        var warnings: UInt32 = 0
        let context = Unmanaged.passUnretained(reader).toOpaque()
        let result = oh_ntfs_open(ntfsReadCallback, context, reader.deviceSize,
                                  &handle, &warnings)
        guard result == 0, let handle else {
            return (nil, posixError(Int32(result)))
        }
        return (OpenHDDVolume(handle: handle, reader: reader, warnings: warnings), nil)
    }

    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource,
              let reader = NTFSBlockReader(block) else {
            reply(.notRecognized, nil)
            return
        }
        let size = Int(reader.sectorSize)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: size)
        defer { bytes.deallocate() }
        guard reader.read(offset: 0, into: bytes, count: UInt64(size)) == size else {
            reply(.notRecognized, nil)
            return
        }
        let boot = bytes.assumingMemoryBound(to: UInt8.self)
        let signature: [UInt8] = [78, 84, 70, 83, 32, 32, 32, 32]
        guard Array(UnsafeBufferPointer(start: boot.advanced(by: 3), count: 8)) == signature,
              boot[510] == 0x55, boot[511] == 0xAA else {
            reply(.notRecognized, nil)
            return
        }
        reply(.usable(name: "NTFS", containerID: FSContainerIdentifier()), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, Error?) -> Void) {
        let readOnly = options.taskOptions.contains("--rdonly") ||
                       options.taskOptions.contains("-r")
        guard readOnly else {
            reply(nil, posixError(EROFS))
            return
        }
        // The kernel mount is requested with -r. The adapter enforces RO independently.
        let (volume, error) = open(resource)
        if let volume {
            loaded = volume
            containerStatus = .ready
        } else if let error {
            containerStatus = .blocked(status: error)
        }
        auditBlockWrites()
        reply(volume, error)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping (Error?) -> Void) {
        loaded = nil
        containerStatus = .notReady(status: posixError(ENODEV))
        auditBlockWrites()
        reply(nil)
    }

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Structural readability check only. No repair, replay, or write.
        let progress = Progress(totalUnitCount: 1)
        guard let resource = loaded?.reader.resource else {
            throw posixError(ENODEV)
        }
        let (checked, error) = open(resource)
        if let error {
            auditBlockWrites()
            task.didComplete(error: error)
            return progress
        }
        _ = checked
        progress.completedUnitCount = 1
        auditBlockWrites()
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(EROFS)
    }
}
