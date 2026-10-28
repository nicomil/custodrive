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
| `Tests/run-recovery-probe.sh` | diari contraffatti/troncati, alias NTFS, riferimenti MFT obsoleti, hash sostituzione, rinomina cartelle e recupero nuovamente interrotto; copie di cartelle interrotte (diario v3) senza cartelle vuote residue; rifiuti senza modifiche all'immagine |
| `Tests/run-copy-scanner-test.sh` | confronto della copia con il disco senza disco: cartelle esistenti da unire, file d'intralcio |
| `Tests/run-ui-selftest.sh IMMAGINE` | immagine MBR sacrificabile con `old.bin` e `Documenti`: drop, trascinamento, Quick Look non modificabile, copia esportata conservata dopo fine sessione |
| `OPENHDD_CAMPAIGN_EDIT=… Tests/run-powercut-campaign.sh` | tagli di corrente a ogni scrittura (copia, cartelle, sostituzione, spostamento, rinomina, nuova cartella, eliminazione) |
| `Tests/prepare-windows-v3-cases.sh` + `Tests/windows/verify-v1-cases.ps1` | verifica `chkdsk` su Windows di casi completati, interrotti e tagliati |
| `Tests/verify-windows-roundtrip.py CASES WINDOWS_RESULTS NEW_OUTPUT` | copie dei VHD riparati da Windows: ispezione Mac senza scritture, recupero, nomi finali e hash |

### Come leggere gli esiti

`run-powercut-campaign.sh` distingue **LOCAL PASS** (nessuna violazione
locale rilevata) da recuperabilità. Se esistono casi marcati, danneggiati o
illeggibili restituisce **77 / INCONCLUSIVE**, anche senza violazioni locali.
Uscita 1 indica errore; uscita 0 richiede nessun caso ancora da riparare.
Gli script di preparazione Windows accettano 77 per proseguire l'esportazione,
senza convertirlo in una prova di recupero superata.

Ogni campagna salva `summary.json`, `cases.tsv`, baseline, input, commit,
diff locale e hash del motore in `Build/evidence/powercut/`. L'esportazione
per Windows contiene campioni, non tutti i casi irrisolti. La verifica
PowerShell rifiuta selezioni vuote, conserva le copie fallite e restituisce
77 se i contenuti sopravvivono soltanto in percorsi diversi (`PASS_MOVED`).
Verifica filesystem e file elencati: **non** certifica il successivo recupero
del diario sul Mac. Per questo passaggio occorre conservare `repaired.vhd`
con `-KeepRepaired`, estrarne una copia della partizione e verificare il
motore Mac, nomi e hash finali. Gli originali non vanno montati in scrittura.

Il diario v2 viene validato integralmente prima di scrivere, usando identità
MFT e hash dei contenuti sostituiti. Diari legacy ambigui vengono rifiutati
e conservati. Specifica e limiti: [piano corrente](piano-scrittura-v1.md#perimetro-attuale--29-settembre-2026).

La sessione esegue `inspect-recovery` prima della prima modifica. Il comando
riusa il piano di recupero del motore e non scrive. Su rifiuto conserva motivo,
numero di voce, percorsi attesi e riferimenti MFT; l'app blocca le modifiche,
mostra anche i temporanei e permette di esportare dati e rapporto sul Mac.
I percorsi sono aspettative del diario, non risultati di una ricerca in
`found.000`. Per cartelle intere si riusa il Finder, montato in sola lettura.
Il nuovo controllo rimuove il blocco solo dopo una validazione completa;
nessuna cancellazione del diario o opzione di forzatura.

`OPENHDD_UI_SELFTEST_RECOVERY=1 Tests/run-ui-selftest.sh IMMAGINE` usa una
fixture MBR con `old.bin`, `Documenti` e un diario con entrambi i nomi mancanti.
Verifica banner, rapporto, esportazione, controlli ripetuti e identità
byte per byte dell'immagine prima/dopo. `OPENHDD_UI_EVIDENCE=DIR` conserva
rapporto e schermata. La modalità normale resta il collaudo di modifica.

Compatibilità: le build precedenti non leggono i diari v2. Prima di usare
questa versione su un disco condiviso, aggiornare tutti i Mac coinvolti.
Le build vecchie non devono tentare il recupero di una sessione v2 interrotta.

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

## Verifica locale del 29 settembre 2026

Branch `codex/recovery-hardening`, Mac Apple Silicon con macOS 27:
build Release e suite bridge, copia, modifiche, v3, sessione e recupero
superate. Self-test
dell'app superato su immagine MBR sacrificabile: anteprima non modificabile
(anche con salvataggio atomico), esportazione conservata dopo fine sessione,
rimontaggio pulito e contenuti verificati.

Campagne con un seme, interruzione a ogni scrittura:

| Operazione | Settore simulato | Casi | Intatti | Marcati | Illeggibili | Violazioni locali |
|---|---:|---:|---:|---:|---:|---:|
| Copia | 512 B | 21 | 1 | 6 | 14 | 0 |
| Sostituzione | 512 B | 48 | 1 | 12 | 35 | 0 |
| Rinomina | 512 B | 25 | 1 | 6 | 18 | 0 |
| Copia | 4096 B | 21 | 1 | 17 | 3 | 0 |

Totale **115 casi**, 111 ancora da verificare su Windows: tutte le campagne
terminano con 77, non con un PASS di recuperabilità. Nessuna prova su disco
fisico in questa verifica. Gli script PowerShell sono stati modificati ma
non eseguiti: runtime PowerShell e ambiente Windows non disponibili in
questa sessione. Gli esiti storici sotto non colmano questa lacuna.

## Collaudo assistenza al recupero — 30 settembre 2026

Suite bridge, copia v1, modifiche v2, v3, sessione e recupero superate.
Self-test normale e rifiuto del recupero superati su immagini sacrificabili;
nel secondo caso l'immagine resta identica byte per byte dopo ispezioni,
esportazione, nuova verifica e chiusura. Build Release verificata.

Matrice aggiuntiva: un seme per operazione e settore simulato, taglio a ogni scrittura.
I 4096 B modellano la granularità dello strappo, non una prova su hardware 4Kn.
Le campagne usano fixture diverse: confrontare i conteggi solo con la
baseline e la provenienza registrate per ciascuna campagna.

| Operazione | Settore | Casi | Intatti | Marcati | Illeggibili | Violazioni locali |
|---|---:|---:|---:|---:|---:|---:|
| replace | 512 B | 42 | 1 | 10 | 31 | 0 |
| replace | 4096 B | 42 | 1 | 36 | 5 | 0 |
| move | 512 B | 22 | 1 | 11 | 10 | 0 |
| move | 4096 B | 22 | 1 | 18 | 3 | 0 |
| tree | 512 B | 38 | 1 | 13 | 24 | 0 |
| rename | 512 B | 22 | 1 | 5 | 16 | 0 |
| rename | 4096 B | 22 | 1 | 18 | 3 | 0 |
| copy | 512 B | 21 | 1 | 6 | 14 | 0 |
| copy | 4096 B | 21 | 1 | 17 | 3 | 0 |
| tree | 4096 B | 50 | 1 | 43 | 6 | 0 |
| delete | 512 B | 18 | 1 | 8 | 9 | 0 |
| delete | 4096 B | 18 | 1 | 15 | 2 | 0 |
| mkdir | 512 B | 10 | 1 | 4 | 5 | 0 |
| mkdir | 4096 B | 10 | 1 | 6 | 3 | 0 |

**358 casi, zero violazioni locali, 344 casi che richiedono Windows**:
le 14 campagne restituiscono 77. Questo numero descrive lo stato locale,
non un'affermazione che tutti i casi siano stati recuperati.

Il laboratorio Windows ha verificato **89/89 casi PASS**, inclusi stati
interrotti del diario v2, rinomine di cartelle in radice/annidate e campioni
powercut a 512 B/4 KiB. Il verificatore usa soltanto copie private e conserva
originali, log `chkdsk`, hash e VHD riparati. I campioni non coprono tutti i
344 casi irrisolti delle campagne.

Evidenze locali: `Build/evidence/recovery-assistance-20260929/`;
Windows: `C:\OpenHDD-Lab\recovery-assistance-20260929-2146`. Il nome della
cartella riflette l'avvio della campagna, non la data di completamento.
Il giro di ritorno usa `verify-windows-roundtrip.py` su copie delle partizioni
riparate; il suo `summary.json` distingue PASS, rifiuto senza scritture
(INCONCLUSIVE) e violazione (FAIL). L'uscita 77 non chiude il gate.

Esito Windows → Mac: **77 PASS, 12 INCONCLUSIVE, zero FAIL**. Tutti i 17
casi funzionali (inclusi sostituzione, spostamento e le quattro rinomine
di cartella interrotte) completano il recupero. Nei campioni powercut restano
6 checksum non validi, 4 coppie di nomi mancanti e 2 cartelle genitrici
mancanti. Il motore li rifiuta senza modificare un byte. Per tutti e 12,
l'esportazione dei contenuti attesi supera gli hash; cinque casi contengono
file spostati da Windows sotto `found.000`. È salvataggio in sola lettura,
non completamento automatico del recupero.

Il primo giro di collaudo chiedeva erroneamente di conservare il vecchio
backup dopo una sostituzione già pubblicata (`v3-abort-replace-stage5`).
L'aspettativa corretta richiede il nuovo hash al nome finale; il backup può
essere eliminato dopo la verifica del diario. Il controllo è stato corretto
senza cambiare il motore; primo esito e riesecuzione restano conservati in
`mac-roundtrip/` e `mac-roundtrip-verified/`.

La recuperabilità automatica non è dimostrata per tutti i casi: i 12
rifiuti restano rifiuti sicuri (nessuna scrittura, contenuti esportabili con
hash corretti). Non eliminare i loro diari per far passare il gate.

Il 28 ottobre 2026, dopo la prova su chiavetta reale (sezione sotto) e con
tutte le suite automatiche superate, il branch è stato unito a `main` per
decisione del proprietario. Restano aperti la prova su un secondo Mac e le
due osservazioni della prova su chiavetta; pacchetto di rilascio e
sostituzione dell'app installata sono decisioni separate.

Restano separati i limiti del filesystem dal recupero applicativo, le prove
hardware USB e il secondo Mac. Nessuna prova fisica svolta in questa campagna.

## Collaudo su chiavetta reale con diario v2 — 28 ottobre 2026

Prova fisica eseguita da remoto: il Mac era fuori casa e il minipc Windows
raggiunto via WireGuard (~2 MB/s). Per contenere i trasferimenti, Windows ha
creato con `diskpart` un VHD fisso da 320 MB (MBR, una partizione NTFS
formattata da Windows); il suo contenuto grezzo è stato scritto all'inizio di
una chiavetta sacrificabile (Kingston DataTraveler G3, 16 GB). Ogni giro:
scollegamento fisico durante l'operazione, copia dei primi 320 MB della
chiavetta in un VHD, `chkdsk /f` su Windows su una copia privata, riscrittura
del VHD riparato sulla chiavetta con rilettura e confronto SHA-256, ripresa
nell'app Custodrive (build `0934112`), verifica degli hash dal Mac.

| Prova | Operazione interrotta | Stato dopo lo stacco | Windows | Ripresa sul Mac |
|---|---|---|---|---|
| 1 | sostituzione di un file da 140 MB | dirty, 1 temporaneo parziale | `chkdsk` pulito dopo /f | temporaneo rimosso, file vecchio intatto |
| 2 | copia di una cartella da 300 file | dirty, 300 temporanei nella radice | `chkdsk` pulito dopo /f | temporanei rimossi, file preesistenti intatti; **resta la cartella di destinazione vuota** |
| 3 | eliminazione di quella cartella | dirty, 69 file eliminati e 231 intatti | `chkdsk` pulito dopo /f | i 231 file restano integri; l'eliminazione si completa con una nuova richiesta |

Prima di ogni ripresa, il controllo in sola lettura del motore rifiuta il
volume sporco (`volume-needs-check`) senza scrivere e accetta lo stesso volume
dopo la riparazione di Windows. Dopo le tre prove il volume è pulito
(`dirty=0 pending=0`), contiene esattamente i 21 file attesi con gli hash
originali, e un ultimo `chkdsk` su Windows non trova problemi.

Osservazioni, corrette lo stesso giorno (vedi il diario delle cartelle in
[piano-scrittura-v1.md](piano-scrittura-v1.md)):
- dopo una copia di cartella interrotta e ripristinata, le cartelle create
  dal lotto restavano vuote, mentre l'annullamento dall'app le rimuove: il
  diario non registrava le cartelle create. Ora un diario v3 le registra e il
  ripristino toglie quelle ancora vuote;
- copiando una cartella su una cartella esistente con lo stesso nome, l'app
  univa senza chiedere. Ora chiede «Unisci / Annulla» prima della domanda sui
  file già presenti.

Correzioni verificate su immagini (probe di ripristino, nuovo test del
confronto, campagna di tagli `tree`: 256 casi, zero violazioni locali); la
prova su chiavetta reale non è stata ripetuta dopo le correzioni.

Nota di metodo: in un giro la riscrittura con `authopen -w` alimentato da
una pipe ha restituito successo senza che i settori riparati arrivassero sulla
chiavetta. La rilettura di controllo l'ha scoperto; gli script ora leggono da
file e confrontano sempre l'hash della chiavetta dopo la scrittura.

Evidenze: `Build/evidence/usb2-20261028/` (script, hash, esiti e log di
`chkdsk`); VHD di ogni giro su Windows in `C:\OpenHDD-Lab\usb2-20261028`.
Restano da fare: prova su un secondo Mac e decisione sui 12 rifiuti del
collaudo del 30 settembre.

## Collaudo storico della scrittura

Gli esiti del 28 settembre qui sotto sono registrazioni delle versioni
precedenti, non una ricertificazione del branch `codex/recovery-hardening`.
Per il nuovo diario valgono gli esiti dei collaudi correnti sopra: la prova
su chiavetta sacrificabile è stata ripetuta il 28 ottobre 2026, quella su un
secondo Mac resta da fare; i risultati storici e le simulazioni locali non la
sostituiscono.

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
