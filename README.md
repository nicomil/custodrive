# OpenHDD — lettura gratuita e ricerca sulla scrittura NTFS

**OpenHDD Local** è la build gratuita utilizzabile senza team Apple Developer. Usa il driver macOS per leggere NTFS nel Finder, monta esplicitamente in sola lettura e permette l'espulsione normale. Per APFS/exFAT/FAT/HFS usa macOS. Non scrive su NTFS. Per il percorso verso la scrittura vedere [docs/percorso-senza-abbonamento.md](docs/percorso-senza-abbonamento.md).

```sh
Scripts/build-local-app.sh
open Build/OpenHDDLocal.app
```

Il risultato è in `Build/OpenHDDLocal.app`, firmato localmente ad hoc. Non richiede l'estensione FSKit di OpenHDD né una quota annuale Apple. In caso di disco NTFS già montato, l'app controlla che il mount sia davvero read-only prima di aprire Finder. Per espellere, smonta normalmente tutti i volumi del dispositivo e chiede l'eject; non usa l'opzione force.

**Prova runtime su macOS 27:** immagine GPT/NTFS sacrificabile da 128 MiB collegata in sola lettura; rilevata come partizione esterna, montata da OpenHDD Local in `/Volumes/OpenHDDTest` con flag `read-only`, file ASCII e Unicode letti, espulsione riuscita, hash SHA-256 dell'immagine invariato. La prova non dimostra compatibilità su un M1/macOS 15.4 né su un dispositivo fisico.

**Scrittura NTFS non abilitata nell'app.** `Tests/run-offline-write-probe.sh` verifica un precedente motore sperimentale solo su immagini: copia di file grande, Unicode e vuoto con confronto SHA-256; rifiuto di duplicati, dirty, ibernazione simulata e non NTFS; errore iniettato senza falso successo. Il vecchio motore non deve essere usato su dispositivi fisici.

Il nuovo `Build/OpenHDDCopy` è un programma **sperimentale per la prova fisica controllata**. Usa un descrittore del disco aperto in modo esclusivo, Disk Arbitration per smontaggio e possesso esclusivo, crea un nome temporaneo, verifica SHA-256 prima e dopo la pubblicazione e tenta l'espulsione normale. Test su immagini: `Tests/run-direct-copy-probe.sh`. Procedura e risultati USB: [docs/prova-copia-ntfs.md](docs/prova-copia-ntfs.md). Sulla Kingston da 16 GB le copie da 8 e 128 MiB avevano hash corretti su Mac e, secondo l'utente, su Windows con `chkdsk` senza errori; successive letture hanno però prodotto errori I/O, quindi la Kingston è stata ritirata. `certutil` fallisce con 1006 anche per un file vuoto locale Windows e non è un controllo utile in questo ambiente. I test su immagini iniettano errori di lettura, scrittura, sync e spazio esaurito; il binario dei test non accetta dischi fisici. L'app resta in sola lettura; il programma non è validato per dati importanti.

La versione corrente del motore rifiuta ogni temporaneo `.OpenHDD-pending-...` ed elimina il nome temporaneo solo dopo pubblicazione e verifica riuscite. Ha superato i test su immagini private, inclusi I/O parziali e arresti ai confini della pubblicazione. Sulla USB sacrificabile `OPENHDDLAB`, dopo formattazione NTFS da Windows, ha copiato file da 0, 1 e 65 byte, 8 MiB e 128 MiB: il Mac li ha riletti in sola lettura con hash corrispondenti e senza temporanei. L'utente riferisce `chkdsk` senza errori e hash Windows corrispondenti per tutti e cinque. **La successiva prova di scollegamento durante una copia da 2 GiB ha rilevato errori NTFS con `chkdsk` su Windows.** Il programma ha segnalato errore e non `PASS`, ma il criterio di integrità non è soddisfatto: la scrittura diretta resta sperimentale e assente dall'app. La sezione seguente descrive l'originaria variante FSKit, ancora non attivabile senza firma idonea.

App macOS per aprire manualmente partizioni NTFS esterne **in sola lettura**. Target: Apple Silicon, macOS 15.4 o successivo. Questa fase non contiene operazioni NTFS di scrittura, riparazione, replay del journal o formattazione.

## Stato verificato

- Progetto Xcode arm64 compilato con Xcode 27 e deployment target 15.4.
- NTFS-3G 2026.7.7 verificato contro archivio upstream e compilato come libreria statica. Provenienza e licenza: [vendor/README.md](vendor/README.md).
- Test dell'adattatore su immagini NTFS sacrificabili: file normale, vuoto, Unicode e 2 MiB di dati confrontati byte per byte; avvisi per dirty bit e ibernazione simulata; SHA-256 invariato dopo ogni lettura; zero chiamate di scrittura a blocchi; immagine non NTFS rifiutata.
- Fixture GPT/NTFS generata offline con `Tests/create-runtime-fixture.sh`; macOS 27 l'ha riconosciuta come partizione NTFS esterna in sola lettura. Nessun mount FSKit eseguito.
- La firma di sviluppo è bloccata su questo Mac: il portachiavi non contiene identità valide e l'account Apple Developer mostra l'iscrizione al programma scaduta. La [tabella Apple per macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos) indica FSKit Module per Apple Developer Program e Developer ID, non per Apple Developer gratuito. Nessuna estensione è stata attivata.
- **Non ancora validato su FSKit/Finder né su disco fisico.** Non usare con dati insostituibili finché la matrice sotto non è completata.

## Struttura

- `Sources/OpenHDDApp`: finestra SwiftUI e inventario Disk Arbitration. Nessun mount automatico.
- `Sources/NTFSExtension`: estensione FSKit. Accetta il caricamento solo con opzione read-only; tutte le operazioni di modifica restituiscono `EROFS`.
- `Sources/NTFSBridge`: adattatore NTFS-3G con dispositivo a blocchi soltanto leggibile. `write` e `pwrite` restituiscono `EROFS` e incrementano contatori.
- `Sources/DiskHelper`: helper privilegiato limitato a mount NTFS read-only, unmount del proprio mount ed eject. Rivalida partizione, dimensione e identità del dispositivo. Non accetta percorsi o comandi arbitrari.
- `Tests`: prova automatica dell'adattatore su immagine temporanea; non tocca dischi esterni.

## Build

Prerequisiti: Xcode completo, XcodeGen, certificato e team di sviluppo compatibili con entitlement FSKit. La [matrice Apple](https://developer.apple.com/help/account/reference/supported-capabilities-macos) non include FSKit nel profilo gratuito; occorre una firma idonea prima delle prove runtime. Firma app, estensione e helper con lo stesso Team ID. L'estensione richiede l'entitlement `com.apple.developer.fskit.fsmodule`. Non rimuovere l'entitlement né abbassare la sicurezza di avvio per aggirare una firma mancante.

```sh
PROJECT_DIR="$PWD" Scripts/build-ntfs3g.sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project OpenHDD.xcodeproj -scheme OpenHDD -configuration Debug \
  -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO build
Tests/run-bridge-test.sh
Tests/create-runtime-fixture.sh Build/runtime-fixture.img
```

Installare l'app firmata in `/Applications`. In **Impostazioni di sistema > Generali > Elementi login ed estensioni > Estensioni file system**, attivare OpenHDD NTFS. Alla prima richiesta, approvare anche l'helper OpenHDD. La build senza firma serve solo al controllo del codice e **non** abilita FSKit.

## Uso previsto

Selezionare una partizione esterna. Per NTFS, premere **Apri in sola lettura**: l'helper esegue una verifica strutturale limitata, smonta normalmente un eventuale mount macOS, poi chiede il mount FSKit read-only. Se il mount fallisce, prova a ripristinare quello macOS in sola lettura e mostra l'esito. Con il volume montato, usare **Apri nel Finder** e poi **Espelli**. Per APFS/exFAT/FAT/HFS, il mount rimane affidato a macOS.

Dirty bit, sospetto journal e stato di ibernazione incerto producono avvisi: il controllo non è una riparazione né un fsck completo. File NTFS cifrati e reparse point non sono letti dall'adattatore.

## Prove necessarie prima di dichiarare conclusa la fase 1

Usare **solo immagini e unità sacrificabili**. Registrare per ogni prova sistema, Mac, build, hash prima/dopo, stato del mount ed esito osservato.

1. Attivazione estensione e helper firmati; mount manuale in `/Volumes` su M1/macOS 15.4 e su un secondo Apple Silicon; lettura Finder e Terminale.
2. File piccoli, grandi, vuoti, Unicode, sparsi e compressi: confronto dimensioni e hash con copie note. Il test automatico attuale non copre ancora file NTFS sparsi e compressi.
3. Creazione, sovrascrittura, rename, cancellazione e modifica attributi da Finder e Terminale: ogni operazione deve fallire con filesystem read-only. Controllare zero scritture a blocchi durante mount, lettura, errore ed eject, più hash dell'intera immagine invariato.
4. Volume dirty, ibernato, danneggiato e non NTFS: avviso o rifiuto coerente, nessuna riparazione automatica. Ripetere con dispositivo occupato, scollegamento durante lettura, estensione terminata e identità cambiata.
5. Fallimento del nuovo mount dopo smontaggio nativo: verificare il tentativo di ripristino read-only e il messaggio preciso. Verificare eject normale senza forza.
6. Controllare che log applicativi non contengano nomi o contenuti dei file. La build con target 15.4 non sostituisce la prova runtime su 15.4.

Finché queste prove non passano, **OpenHDD resta prototipo non adatto a dati importanti**.

I due processi registrano solo `block_write_attempts=<numero>` nei sottosistemi `it.openhdd.app.ntfs` e `it.openhdd.app.helper`, categoria `integrity`. Durante il collaudo, filtrare questi eventi con `log show --predicate '(subsystem == "it.openhdd.app.ntfs" || subsystem == "it.openhdd.app.helper") && category == "integrity"'`; ogni valore deve essere zero. Nessun nome o contenuto dei file viene registrato dal codice OpenHDD.
