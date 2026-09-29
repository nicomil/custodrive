# Custodrive — note per sviluppatori

Build, motore di scrittura, collaudo e storia del progetto. Per l'uso
dell'app vedi il [README](../README.md); il protocollo di scrittura e le
decisioni di progetto sono in [piano-scrittura-v1.md](piano-scrittura-v1.md).

## Build e pacchetto

```sh
Scripts/build-local-app.sh      # Build/Custodrive.app (motore incluso e firmato ad-hoc)
Scripts/package-app.sh          # Build/Custodrive-VERSIONE.dmg da condividere
swift Scripts/make-icon.swift OUT.iconset && iconutil -c icns OUT.iconset -o Resources/AppIcon.icns
```

Prerequisiti: Xcode completo e XcodeGen. Il progetto (`project.yml`) genera
due target: **OpenHDDLocal** (prodotto `Custodrive.app`, nessun abbonamento
Apple necessario) e **OpenHDD** (variante FSKit, sotto). I nomi interni
`OpenHDD*` e i temporanei su disco `.OpenHDD-*` restano invariati: fanno
parte del formato che il recupero riconosce.

## Test automatici

| Script | Cosa verifica |
|---|---|
| `Tests/run-direct-copy-probe.sh` | copia v1: dirty bit, crash, errori I/O, disco pieno, lotti, nomi Unicode |
| `Tests/run-edit-probe.sh` | nuova cartella, rinomina, eliminazione, rifiuti, interruzioni |
| `Tests/run-v3-probe.sh` | cartelle, 300 file per lotto, sostituzione con diario, spostamento, annullamento |
| `Tests/run-session-probe.sh` | sessione di modifica: protocollo, sfoglia, esporta, rifiuti, fine input, annullamento |
| `Tests/run-ui-selftest.sh IMMAGINE` | interfaccia vera: drop dal Finder, trascinamento, Quick Look, sessione |
| `OPENHDD_CAMPAIGN_EDIT=… Tests/run-powercut-campaign.sh` | tagli di corrente a ogni scrittura (copia, cartelle, sostituzione, spostamento, rinomina, nuova cartella, eliminazione) |
| `Tests/prepare-windows-v3-cases.sh` + `Tests/windows/verify-v1-cases.ps1` | verifica `chkdsk` su Windows di casi completati, interrotti e tagliati |

## Motore da riga di comando

Il motore dell'app è `Build/OpenHDDCopy` (anche in
`Custodrive.app/Contents/Resources/`):

```sh
sudo Build/OpenHDDCopy --disk disk4s1 [--dir "Cartella/Sotto"] [--replace] FILE1 "Nome 1" FILE2 "Nome 2"
sudo Build/OpenHDDCopy --disk disk4s1 --manifest ELENCO   # cartelle intere (formato in --help)
sudo Build/OpenHDDCopy --check-disk disk4s1        # controllo in sola lettura
sudo Build/OpenHDDCopy --disk disk4s1 --mkdir "Foto" "Estate 2026"
sudo Build/OpenHDDCopy --disk disk4s1 --rename "Foto/Estate 2026" "Estate 2026 mare"
sudo Build/OpenHDDCopy --disk disk4s1 --move "Archivio" "Foto/Estate 2026"
sudo Build/OpenHDDCopy --disk disk4s1 --delete "vecchio.bin"
Build/OpenHDDCopy --disk disk4s1 --session --yes   # sessione di modifica (protocollo in docs/piano-scrittura-v1.md)
```

## Collaudo della scrittura

| Gate | Prova | Esito (28 settembre 2026) |
|---|---|---|
| V1 | `Tests/run-direct-copy-probe.sh`: dirty bit a ogni confine, crash, errori I/O, disco pieno, batch, nomi Unicode e NFD→NFC, cartelle, duplicati senza distinzione maiuscole, pulizia dei temporanei | PASS |
| V1 | `Tests/run-powercut-campaign.sh`: taglio di corrente con cache volatile a **ogni** scrittura di una copia, 4 semi, strappi a 512 B e 4 KiB (680 casi) | PASS: 0 volumi "puliti ma alterati" |
| V2 | `Tests/prepare-windows-v1-cases.sh` + `Tests/windows/verify-v1-cases.ps1` su una base formattata da Windows 11 (build 26200): copia completata, 3 interruzioni a stadi precisi, 18 tagli di corrente | **22/22 PASS**: copia completata con `chkdsk` pulito; ogni interruzione riparata da `chkdsk /f`, secondo `chkdsk` pulito, file preesistenti intatti al loro posto |
| V3 | Copia su un disco collegato a macOS (`hdiutil`) con la CLI e **dall'interfaccia dell'app** (selezione disco, scelta file, destinazione, conferma), rimontaggio in sola lettura, poi verifica su Windows | PASS: `chkdsk` pulito, hash corretti |
| V4 | Chiavetta USB 2.0 reale (`USB DISK 2.0`, 3,9 GB) formattata da Windows: copie da 1,5 GB, scollegamento fisico durante la scrittura, riparazione su Windows, ripresa dal Mac | **PASS** (28 settembre 2026): dopo lo scollegamento Windows vede il volume da controllare, `chkdsk` non trova incoerenze, nessun file a metà pubblicato; la copia successiva pulisce e completa; controllo finale `chkdsk` pulito e tutti gli hash corretti |

I test su immagini non sostituiscono il collaudo sull'hardware reale: il
controller USB può riordinare o perdere scritture in modi che il simulatore non
riproduce.

### Checklist V4 (USB sacrificabile)

1. Formatta la chiavetta NTFS su Windows, aggiungi alcuni file e annota gli
   hash (`Get-FileHash`). Espelli.
2. Sul Mac copia con OpenHDD un file piccolo e uno da qualche GiB. Controlla gli
   hash nel Finder o con `shasum -a 256`. Su Windows: `chkdsk X:` deve essere
   pulito e gli hash devono coincidere.
3. Avvia una copia da qualche GiB e scollega la chiavetta a metà. L'app deve
   dire «Copia non completata». Su Windows il disco deve risultare da
   controllare (`fsutil dirty query X:`). `chkdsk X: /f`, poi `chkdsk X:`
   pulito; i file iniziali devono avere gli stessi hash.
4. Ricollega al Mac e copia un altro file: OpenHDD deve rimuovere il temporaneo
   rimasto e completare la copia.

## Storia e ricerca

La prima prova di scollegamento del 27 settembre, con il vecchio motore senza
dirty bit, aveva lasciato `$Bitmap` incoerente senza che Windows lo sapesse:
[analisi forense](docs/analisi-guasto-bitmap-ntfs-2026-09-27.md). La
[specifica transazionale](docs/specifica-recupero-transazionale-ntfs.md) resta
come fase 2, per un recupero via journal `$LogFile` senza `chkdsk`, insieme al
laboratorio in `Tests/windows/` (`verify-journal-recovery.ps1`,
`acquire-logfile-replay_claude.ps1`, `export-vhd-partition.ps1`) e a
`Tests/run-journal-probe.sh`. Non blocca la v1.

## Variante FSKit (richiede firma Apple Developer)

App macOS per aprire manualmente partizioni NTFS esterne **in sola lettura**. Target: Apple Silicon, macOS 15.4 o successivo. Questa fase non contiene operazioni NTFS di scrittura, riparazione, replay del journal o formattazione.

### Stato verificato

- Progetto Xcode arm64 compilato con Xcode 27 e deployment target 15.4.
- NTFS-3G 2026.7.7 verificato contro archivio upstream e compilato come libreria statica. Provenienza e licenza: [vendor/README.md](vendor/README.md).
- Test dell'adattatore su immagini NTFS sacrificabili: file normale, vuoto, Unicode e 2 MiB di dati confrontati byte per byte; avvisi per dirty bit e ibernazione simulata; SHA-256 invariato dopo ogni lettura; zero chiamate di scrittura a blocchi; immagine non NTFS rifiutata.
- Fixture GPT/NTFS generata offline con `Tests/create-runtime-fixture.sh`; macOS 27 l'ha riconosciuta come partizione NTFS esterna in sola lettura. Nessun mount FSKit eseguito.
- La firma di sviluppo è bloccata su questo Mac: il portachiavi non contiene identità valide e l'account Apple Developer mostra l'iscrizione al programma scaduta. La [tabella Apple per macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos) indica FSKit Module per Apple Developer Program e Developer ID, non per Apple Developer gratuito. Nessuna estensione è stata attivata.
- **Non ancora validato su FSKit/Finder né su disco fisico.** Non usare con dati insostituibili finché la matrice sotto non è completata.

### Struttura

- `Sources/OpenHDDApp`: finestra SwiftUI e inventario Disk Arbitration. Nessun mount automatico.
- `Sources/NTFSExtension`: estensione FSKit. Accetta il caricamento solo con opzione read-only; tutte le operazioni di modifica restituiscono `EROFS`.
- `Sources/NTFSBridge`: adattatore NTFS-3G con dispositivo a blocchi soltanto leggibile. `write` e `pwrite` restituiscono `EROFS` e incrementano contatori.
- `Sources/DiskHelper`: helper privilegiato limitato a mount NTFS read-only, unmount del proprio mount ed eject. Rivalida partizione, dimensione e identità del dispositivo. Non accetta percorsi o comandi arbitrari.
- `Tests`: prova automatica dell'adattatore su immagine temporanea; non tocca dischi esterni.

### Build

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

### Uso previsto

Selezionare una partizione esterna. Per NTFS, premere **Apri in sola lettura**: l'helper esegue una verifica strutturale limitata, smonta normalmente un eventuale mount macOS, poi chiede il mount FSKit read-only. Se il mount fallisce, prova a ripristinare quello macOS in sola lettura e mostra l'esito. Con il volume montato, usare **Apri nel Finder** e poi **Espelli**. Per APFS/exFAT/FAT/HFS, il mount rimane affidato a macOS.

Dirty bit, sospetto journal e stato di ibernazione incerto producono avvisi: il controllo non è una riparazione né un fsck completo. File NTFS cifrati e reparse point non sono letti dall'adattatore.

### Prove necessarie prima di dichiarare conclusa la fase 1

Usare **solo immagini e unità sacrificabili**. Registrare per ogni prova sistema, Mac, build, hash prima/dopo, stato del mount ed esito osservato.

1. Attivazione estensione e helper firmati; mount manuale in `/Volumes` su M1/macOS 15.4 e su un secondo Apple Silicon; lettura Finder e Terminale.
2. File piccoli, grandi, vuoti, Unicode, sparsi e compressi: confronto dimensioni e hash con copie note. Il test automatico attuale non copre ancora file NTFS sparsi e compressi.
3. Creazione, sovrascrittura, rename, cancellazione e modifica attributi da Finder e Terminale: ogni operazione deve fallire con filesystem read-only. Controllare zero scritture a blocchi durante mount, lettura, errore ed eject, più hash dell'intera immagine invariato.
4. Volume dirty, ibernato, danneggiato e non NTFS: avviso o rifiuto coerente, nessuna riparazione automatica. Ripetere con dispositivo occupato, scollegamento durante lettura, estensione terminata e identità cambiata.
5. Fallimento del nuovo mount dopo smontaggio nativo: verificare il tentativo di ripristino read-only e il messaggio preciso. Verificare eject normale senza forza.
6. Controllare che log applicativi non contengano nomi o contenuti dei file. La build con target 15.4 non sostituisce la prova runtime su 15.4.

Finché queste prove non passano, **OpenHDD resta prototipo non adatto a dati importanti**.

I due processi registrano solo `block_write_attempts=<numero>` nei sottosistemi `it.openhdd.app.ntfs` e `it.openhdd.app.helper`, categoria `integrity`. Durante il collaudo, filtrare questi eventi con `log show --predicate '(subsystem == "it.openhdd.app.ntfs" || subsystem == "it.openhdd.app.helper") && category == "integrity"'`; ogni valore deve essere zero. Nessun nome o contenuto dei file viene registrato dal codice OpenHDD.
