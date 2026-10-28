import Foundation
import ServiceManagement

private final class HelperReply {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: (Int32, String)?

    func finish(_ value: (Int32, String)) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        semaphore.signal()
    }

    func wait() -> (Int32, String) {
        guard semaphore.wait(timeout: .now() + 160) == .success else {
            return (ETIMEDOUT, L("Helper is not responding; disk status needs checking."))
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? (EIO, L("Invalid helper response."))
    }
}

enum HelperClient {
    static func ensureAvailable() -> String? {
        let service = SMAppService.daemon(plistName: DiskIdentity.plistName)
        switch service.status {
        case .enabled:
            return nil
        case .notRegistered:
            do { try service.register() }
            catch { return L("Helper registration failed: \(error.localizedDescription)") }
            return service.status == .enabled ? nil :
                   L("Approve the OpenHDD helper in System Settings, then try again.")
        case .requiresApproval:
            return L("Approve the OpenHDD helper in System Settings, then try again.")
        case .notFound:
            return L("Helper is missing from the installed app.")
        @unknown default:
            return L("Unknown helper status.")
        }
    }

    static func perform(_ operation: String, disk: DiskRecord) -> (Int32, String) {
        let connection = NSXPCConnection(machServiceName: DiskIdentity.serviceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DiskHelperProtocol.self)
        let answer = HelperReply()
        connection.interruptionHandler = { answer.finish((EIO, L("Helper interrupted."))) }
        connection.invalidationHandler = { answer.finish((EIO, L("Helper connection closed."))) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            answer.finish((EIO, L("Helper unavailable: \(error.localizedDescription)")))
        }) as? DiskHelperProtocol else {
            connection.invalidate()
            return (EIO, L("Helper interface unavailable."))
        }
        proxy.perform(operation, bsdName: disk.bsdName,
                      mediaIdentity: disk.mediaIdentity, size: NSNumber(value: disk.size)) {
            code, message in answer.finish((code, message))
        }
        let result = answer.wait()
        connection.invalidate()
        return (result.0, localizedMessage(result.1))
    }

    // The privileged helper may be an older installed build. Translate its
    // known messages here without changing the protocol or diagnostic codes.
    private static func localizedMessage(_ message: String) -> String {
        let phrases: [(String, LocalizedMessage)] = [
            ("Identità del disco cambiata o partizione non NTFS esterna.", "Disk identity changed or partition is not external NTFS."),
            ("Verifica strutturale di sola lettura fallita; mount annullato.", "Read-only structural check failed; mount cancelled."),
            ("Disco occupato: smontaggio normale fallito.", "Disk busy: normal unmount failed."),
            ("Identità cambiata dopo lo smontaggio.", "Identity changed after unmounting."),
            ("Impossibile preparare /Volumes.", "Cannot prepare /Volumes."),
            ("Impossibile preparare /Volumes; ripristino precedente fallito.", "Cannot prepare /Volumes; restoring the previous mount failed."),
            ("Montato in sola lettura.", "Mounted read-only."),
            (" Volume dirty: verifica su Windows consigliata.", " Dirty volume: checking on Windows is recommended."),
            (" Ibernazione o stato incerto: lettura con cautela.", " Hibernation or uncertain state: read with caution."),
            (" Journal sospetto: controllate solo le pagine di riavvio.", " Suspect journal: only restart pages were checked."),
            (" Metadato Windows $TXF_DATA non sicuro per scrittura OpenHDD.", " Windows $TXF_DATA metadata is unsafe for OpenHDD writes."),
            ("Mount fallito; anche il ripristino read-only è fallito.", "Mount failed; read-only restoration also failed."),
            ("Mount fallito; precedente mount read-only ripristinato.", "Mount failed; previous read-only mount restored."),
            ("Mount fallito; nessun volume montato.", "Mount failed; no volume mounted."),
            ("Mount OpenHDD non presente o identità cambiata.", "OpenHDD mount missing or identity changed."),
            ("Smontato.", "Unmounted."),
            ("Disco occupato: nessuno smontaggio forzato.", "Disk busy: no forced unmount."),
            ("Dispositivo cambiato o non presente.", "Device changed or missing."),
            ("Dispositivo espulso.", "Device ejected."),
            ("Espulsione fallita: disco occupato.", "Ejection failed: disk busy."),
            ("Richiesta non valida.", "Invalid request."),
            ("Operazione non permessa.", "Operation not allowed."),
        ]
        return phrases.reduce(message) { result, phrase in
            result.replacingOccurrences(of: phrase.0, with: L(phrase.1))
        }
    }
}
