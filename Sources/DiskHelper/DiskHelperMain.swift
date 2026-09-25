import Foundation
import DiskArbitration
import ServiceManagement
import Security
import Darwin
import OSLog

private let integrityLog = Logger(subsystem: "it.openhdd.app.helper", category: "integrity")

private final class DiskWait {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Int32 = 0
}

private func diskOperationFinished(_ disk: DADisk, _ dissenter: DADissenter?,
                                   _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let wait = Unmanaged<DiskWait>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        switch Int(DADissenterGetStatus(dissenter)) {
        case kDAReturnBusy, kDAReturnExclusiveAccess: wait.result = EBUSY
        case kDAReturnNotFound: wait.result = ENODEV
        case kDAReturnNotPermitted, kDAReturnNotPrivileged: wait.result = EPERM
        default: wait.result = EIO
        }
    } else {
        wait.result = 0
    }
    wait.semaphore.signal()
}

private final class RawReadContext {
    let descriptor: Int32
    let blockSize: UInt64
    let size: UInt64
    init(descriptor: Int32, blockSize: UInt64, size: UInt64) {
        self.descriptor = descriptor
        self.blockSize = blockSize
        self.size = size
    }

    func read(_ offset: UInt64, _ destination: UnsafeMutableRawPointer,
              _ length: UInt64) -> Int64 {
        guard offset <= size, length <= size - offset else { errno = EINVAL; return -1 }
        var done: UInt64 = 0
        while done < length {
            let current = offset + done
            let start = current / blockSize * blockSize
            let leading = current - start
            let amount = min(length - done, 1_048_576)
            let rounded = ((leading + amount + blockSize - 1) / blockSize) * blockSize
            guard rounded <= size - start else { errno = EIO; return -1 }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(rounded),
                                                          alignment: Int(blockSize))
            defer { buffer.deallocate() }
            let n = pread(descriptor, buffer, Int(rounded), off_t(start))
            guard n >= Int(leading + amount) else { errno = EIO; return -1 }
            destination.advanced(by: Int(done)).copyMemory(
                from: buffer.advanced(by: Int(leading)), byteCount: Int(amount))
            done += amount
        }
        return Int64(done)
    }
}

private func rawRead(_ opaque: UnsafeMutableRawPointer?, _ offset: UInt64,
                     _ buffer: UnsafeMutableRawPointer?, _ length: UInt64) -> Int64 {
    guard let opaque, let buffer else { errno = EFAULT; return -1 }
    return Unmanaged<RawReadContext>.fromOpaque(opaque).takeUnretainedValue()
        .read(offset, buffer, length)
}

private final class DiskHelperService: NSObject, DiskHelperProtocol {
    private let session: DASession
    private let queue = DispatchQueue(label: "it.openhdd.diskarbitration")
    private let operations = DispatchQueue(label: "it.openhdd.diskoperations")

    override init() {
        guard let created = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("Disk Arbitration unavailable")
        }
        session = created
        super.init()
        DASessionSetDispatchQueue(session, queue)
    }

    deinit { DASessionSetDispatchQueue(session, nil) }

    private func disk(_ name: String, identity: String, size: UInt64,
                      requireNTFS: Bool = true) -> DADisk? {
        guard DiskIdentity.isPartitionName(name), !identity.isEmpty,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
              let raw = DADiskCopyDescription(disk),
              let desc = raw as? [String: Any] else { return nil }
        func value(_ key: CFString) -> Any? { desc[key as String] }
        guard (value(kDADiskDescriptionMediaWholeKey) as? Bool) == false,
              (value(kDADiskDescriptionDeviceInternalKey) as? Bool) == false ||
              (value(kDADiskDescriptionMediaRemovableKey) as? Bool) == true,
              (!requireNTFS ||
               (value(kDADiskDescriptionVolumeKindKey) as? String)?.lowercased() == "ntfs"),
              (value(kDADiskDescriptionMediaSizeKey) as? NSNumber)?.uint64Value == size,
              DiskIdentity.identity(disk, description: desc) == identity else { return nil }
        return disk
    }

    private func mountedPath(_ disk: DADisk) -> String? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return (desc[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
    }

    private func inspectNTFS(_ disk: DADisk, name: String, size: UInt64) -> (Int32, UInt32) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let block = desc[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber else {
            return (EIO, 0)
        }
        let blockSize = block.uint64Value
        guard blockSize >= 512, blockSize <= 65_536,
              blockSize & (blockSize - 1) == 0, size % blockSize == 0 else {
            return (EINVAL, 0)
        }
        let fd = open("/dev/\(name)", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return (errno, 0) }
        defer { close(fd) }
        let reader = RawReadContext(descriptor: fd, blockSize: blockSize, size: size)
        var volume: OpaquePointer?
        var warnings: UInt32 = 0
        let status = oh_ntfs_open(rawRead, Unmanaged.passUnretained(reader).toOpaque(),
                                  size, &volume, &warnings)
        if let volume { oh_ntfs_close(volume) }
        let attempts = oh_ntfs_total_write_attempts()
        integrityLog.notice("block_write_attempts=\(attempts, privacy: .public)")
        return attempts == 0 ? (Int32(status), warnings) : (EIO, warnings)
    }

    private func waitFor(_ action: (UnsafeMutableRawPointer) -> Void) -> Int32 {
        let box = DiskWait()
        action(Unmanaged.passRetained(box).toOpaque())
        // Disk Arbitration has no cancellation token. Do not make a second
        // state-changing request while the first callback may still arrive.
        box.semaphore.wait()
        return box.result
    }

    private func unmount(_ disk: DADisk) -> Int32 {
        waitFor { context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault),
                          diskOperationFinished, context)
        }
    }

    private func restoreNativeReadOnly(_ disk: DADisk) -> Int32 {
        let arguments = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 2)
        arguments[0] = Unmanaged.passRetained("rdonly" as CFString)
        arguments[1] = nil
        defer {
            arguments[0]?.release()
            arguments.deallocate()
        }
        let result = waitFor { context in
            DADiskMountWithArguments(disk, nil,
                DADiskMountOptions(kDADiskMountOptionDefault),
                diskOperationFinished, context, arguments)
        }
        guard result == 0, let path = mountedPath(disk), isReadOnly(path) else {
            if let path = mountedPath(disk), !isReadOnly(path) { _ = unmount(disk) }
            return result == 0 ? EIO : result
        }
        return 0
    }

    private func safeMountPoint(_ name: String) -> String? {
        let path = "/Volumes/OpenHDD-\(name)"
        let made = path.withCString { mkdir($0, 0o700) == 0 }
        if !made && errno != EEXIST { return nil }
        var info = stat()
        var parent = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              stat("/Volumes", &parent) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_dev == parent.st_dev,
              info.st_uid == 0,
              info.st_mode & 0o022 == 0,
              (try? FileManager.default.contentsOfDirectory(atPath: path).isEmpty) == true
              else { return nil }
        return path
    }

    private func runMount(device: String, path: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = ["-r", "-t", "openhdd_ntfs", device, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + 60) == .success else {
                if process.isRunning { process.terminate() }
                if done.wait(timeout: .now() + 5) != .success {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    // Do not start rollback or another disk operation until
                    // this mount process has definitively exited.
                    process.waitUntilExit()
                }
                return ETIMEDOUT
            }
            return process.terminationStatus == 0 ? 0 : EIO
        } catch { return EIO }
    }

    private func isReadOnly(_ path: String) -> Bool {
        var info = statfs()
        guard path.withCString({ statfs($0, &info) }) == 0,
              info.f_flags & UInt32(MNT_RDONLY) != 0 else { return false }
        return true
    }

    private func mountedReadOnly(_ path: String) -> Bool {
        guard isReadOnly(path) else { return false }
        var info = statfs()
        guard path.withCString({ statfs($0, &info) }) == 0 else { return false }
        let fsType = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        return fsType == "openhdd_ntfs"
    }

    private func mount(_ name: String, identity: String, size: UInt64) -> (Int32, String) {
        guard let original = disk(name, identity: identity, size: size) else {
            return (ENODEV, "Identità del disco cambiata o partizione non NTFS esterna.")
        }
        let (checkStatus, warnings) = inspectNTFS(original, name: name, size: size)
        guard checkStatus == 0 else {
            return (checkStatus, "Verifica strutturale di sola lettura fallita; mount annullato.")
        }
        let hadNativeMount = mountedPath(original) != nil
        if hadNativeMount {
            let status = unmount(original)
            guard status == 0 else { return (status, "Disco occupato: smontaggio normale fallito.") }
        }
        guard disk(name, identity: identity, size: size) != nil else {
            if hadNativeMount { _ = restoreNativeReadOnly(original) }
            return (ENODEV, "Identità cambiata dopo lo smontaggio.")
        }
        guard let path = safeMountPoint(name) else {
            let restored = hadNativeMount ? restoreNativeReadOnly(original) : 0
            return (EACCES, restored == 0 ? "Impossibile preparare /Volumes." :
                    "Impossibile preparare /Volumes; ripristino precedente fallito.")
        }
        let status = runMount(device: "/dev/\(name)", path: path)
        if status == 0 && mountedReadOnly(path),
           disk(name, identity: identity, size: size) != nil {
            var message = "Montato in sola lettura."
            if warnings & UInt32(OH_NTFS_WARNING_DIRTY) != 0 {
                message += " Volume dirty: verifica su Windows consigliata."
            }
            if warnings & UInt32(OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN) != 0 {
                message += " Ibernazione o stato incerto: lettura con cautela."
            }
            if warnings & UInt32(OH_NTFS_WARNING_JOURNAL_SUSPECT) != 0 {
                message += " Journal sospetto: controllate solo le pagine di riavvio."
            }
            if warnings & UInt32(OH_NTFS_WARNING_TXF_REWRITE_RISK) != 0 {
                message += " Metadato Windows $TXF_DATA non sicuro per scrittura OpenHDD."
            }
            return (0, message)
        }
        if let current = disk(name, identity: identity, size: size),
           mountedPath(current) == path {
            _ = unmount(current)
        }
        let restored = hadNativeMount ? restoreNativeReadOnly(original) : 0
        if hadNativeMount && restored != 0 {
            return (EIO, "Mount fallito; anche il ripristino read-only è fallito.")
        }
        return (EIO, hadNativeMount ? "Mount fallito; precedente mount read-only ripristinato." :
                "Mount fallito; nessun volume montato.")
    }

    private func unmountOwn(_ name: String, identity: String, size: UInt64) -> (Int32, String) {
        guard let disk = disk(name, identity: identity, size: size),
              mountedPath(disk) == "/Volumes/OpenHDD-\(name)" else {
            return (ENODEV, "Mount OpenHDD non presente o identità cambiata.")
        }
        let status = unmount(disk)
        return (status, status == 0 ? "Smontato." : "Disco occupato: nessuno smontaggio forzato.")
    }

    private func eject(_ name: String, identity: String, size: UInt64) -> (Int32, String) {
        guard let disk = disk(name, identity: identity, size: size, requireNTFS: false),
              let whole = DADiskCopyWholeDisk(disk) else {
            return (ENODEV, "Dispositivo cambiato o non presente.")
        }
        let status = waitFor { context in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault),
                        diskOperationFinished, context)
        }
        return (status, status == 0 ? "Dispositivo espulso." : "Espulsione fallita: disco occupato.")
    }

    func perform(_ operation: String, bsdName: String, mediaIdentity: String,
                 size: NSNumber, reply: @escaping (Int32, String) -> Void) {
        guard DiskIdentity.isPartitionName(bsdName), !mediaIdentity.isEmpty,
              size.uint64Value > 0 else {
            reply(EINVAL, "Richiesta non valida.")
            return
        }
        operations.async {
            let result: (Int32, String)
            switch operation {
            case "mount-read-only":
                result = self.mount(bsdName, identity: mediaIdentity, size: size.uint64Value)
            case "unmount":
                result = self.unmountOwn(bsdName, identity: mediaIdentity, size: size.uint64Value)
            case "eject":
                result = self.eject(bsdName, identity: mediaIdentity, size: size.uint64Value)
            default:
                result = (EINVAL, "Operazione non permessa.")
            }
            reply(result.0, result.1)
        }
    }
}

private final class HelperListener: NSObject, NSXPCListenerDelegate {
    private let service = DiskHelperService()
    private let requirement: String?

    override init() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
           let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                         &info) == errSecSuccess,
           let details = info as? [String: Any],
           let team = details[kSecCodeInfoTeamIdentifier as String] as? String,
           team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
            requirement = "identifier \"it.openhdd.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        } else {
            requirement = nil
        }
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: DiskHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main
struct DiskHelperMain {
    static func main() {
        let delegate = HelperListener()
        let listener = NSXPCListener(machServiceName: DiskIdentity.serviceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
