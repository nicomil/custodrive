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
            return (ETIMEDOUT, "Helper non risponde; stato del disco da verificare.")
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? (EIO, "Risposta helper non valida.")
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
            catch { return "Registrazione helper fallita: \(error.localizedDescription)" }
            return service.status == .enabled ? nil :
                   "Approva l’helper OpenHDD in Impostazioni di sistema, poi riprova."
        case .requiresApproval:
            return "Approva l’helper OpenHDD in Impostazioni di sistema, poi riprova."
        case .notFound:
            return "Helper non presente nell’app installata."
        @unknown default:
            return "Stato helper non riconosciuto."
        }
    }

    static func perform(_ operation: String, disk: DiskRecord) -> (Int32, String) {
        let connection = NSXPCConnection(machServiceName: DiskIdentity.serviceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DiskHelperProtocol.self)
        let answer = HelperReply()
        connection.interruptionHandler = { answer.finish((EIO, "Helper interrotto.")) }
        connection.invalidationHandler = { answer.finish((EIO, "Connessione helper chiusa.")) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            answer.finish((EIO, "Helper non disponibile: \(error.localizedDescription)"))
        }) as? DiskHelperProtocol else {
            connection.invalidate()
            return (EIO, "Interfaccia helper non disponibile.")
        }
        proxy.perform(operation, bsdName: disk.bsdName,
                      mediaIdentity: disk.mediaIdentity, size: NSNumber(value: disk.size)) {
            code, message in answer.finish((code, message))
        }
        let result = answer.wait()
        connection.invalidate()
        return result
    }
}
