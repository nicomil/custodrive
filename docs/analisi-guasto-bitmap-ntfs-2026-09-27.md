# Analisi forense del guasto NTFS — 27 settembre 2026

## Esito

Il gate per la scrittura NTFS transazionale **non è superato**. La prova di scollegamento ha lasciato `$Bitmap` incoerente; Windows ha rilevato l'errore senza ripararlo. I cinque file preesistenti risultano ancora leggibili e con gli hash attesi, ma questo non rende coerente il volume. OpenHDD resta quindi sola lettura nell'app. La build corrente di `Build/OpenHDDCopy` rifiuta scritture su dispositivi fisici; resta utilizzabile sulle sole immagini private.

L'immagine documenta il volume prima di ogni riparazione. Non è stata eseguita alcuna riparazione né nuova scrittura sulla USB dopo il guasto.

La struttura incoerente è riproducibile nell'immagine conservata e i contatori si possono ricalcolare. È stato aggiunto anche un simulatore deterministico di cache volatile, flush, riordino e perdita di alimentazione; i suoi limiti e risultati sono riportati sotto. Questo riproduce la classe di incoerenza, non la sequenza esatta né la quantità di cluster del guasto fisico.

## Prova e reperti conservati

- Dispositivo dichiarato sacrificabile: `USB DISK 2.0`, NTFS `OPENHDDLAB`, collegato a un Mac M1 con macOS 27.0. Geometria acquisita dall'immagine: MBR, settore logico 512 byte, partizione tipo `0x07`, LBA iniziale 8.064, 7.570.944 settori (3.876.323.328 byte); immagine dispositivo 3.880.452.096 byte.
- Codice del workspace al momento della raccolta: commit `4fcb950`; vecchio eseguibile conservato in `Build/evidence/OpenHDDCopy-before-lockout-20260927`, SHA-256 `62143004d4cd3c2a971726f23c1b7bee90618b8982fd72c753727daf938bae2a`, senza permesso di esecuzione. Il motore vendorizzato è NTFS-3G 2026.7.7. Il transcript dell'utente identifica la stessa CLI, ma non registra da solo l'hash del binario effettivamente caricato dal processo; questo digest identifica il binario conservato dopo la prova. La build attuale in `Build/OpenHDDCopy` contiene il blocco delle copie fisiche.
- Prima della prova, il programma aveva riportato preflight read-only riuscito e 3.719.008.256 byte liberi. I cinque file di prova avevano dimensioni e SHA-256 attesi.
- Durante la copia di una sorgente da 2.147.483.648 byte, il programma ha stampato avanzamento fino a 2048 MiB. Queste righe attestano dati elaborati dal programma, non dati persistiti dal dispositivo. Il risultato è stato `Copy failed at stage 2; code 5`, identità cambiata, espulsione automatica saltata e nessun `PASS`.
- Windows ha riconosciuto il volume NTFS. `chkdsk X:` senza `/f` ha completato le fasi 1–3, quindi ha riportato **«Mappa di bit del volume non corretta»** e **«Sono stati rilevati problemi»**; zero settori danneggiati. Non è stata eseguita riparazione. L'utente ha verificato con PowerShell gli hash attesi dei cinque file preesistenti.
- Trascrizione conservata del riepilogo CHKDSK in sola lettura: 256 record file e 278 voci indice elaborati; zero record grandi, non validi, non indicizzati, reparse o orfani; descrittori di sicurezza verificati; 11 file di dati elaborati; «Mappa di bit del volume non corretta»; zero KB in settori danneggiati; 3.785.471 KB totali, 144.448 KB in 12 file, 72 KB in 13 indici, 9.107 KB usati dal sistema (8.320 KB per `$LogFile`), 3.631.844 KB liberi; 946.367 unità di allocazione totali e 907.961 disponibili. CHKDSK ha suggerito `/scan`, ma non è stato eseguito.
- SHA-256 Windows riferiti dall'utente per i cinque file preesistenti: `OpenHDD-v2-empty.bin` (0 byte) `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`; `OpenHDD-v2-one-byte.bin` (1 byte) `2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881`; `OpenHDD-v2-unicode.txt` (65 byte) `85df5f6f0236a4bffdc1d1d06786a688fcbc6d696a28f56879c0160fb4eaf2cd`; `OpenHDD-v2-8MiB.bin` `69f4a57d6d6c0d87ebec0c9b1a275d3f7feb641d0083326137f617654ae52eef`; `OpenHDD-v2-128MiB.bin` `66b2c41461ed686925b342a9bfadc0ceace20319cfd3575465c62da0cf2d566f`. Output PowerShell completo non acquisito; gli hash e l'esito CHKDSK sono riferiti dall'utente.
- Immagine completa raw del dispositivo, acquisita in sola lettura mentre il disco era smontato: `Build/evidence/OPENHDDLAB-20260927.img`, 3.880.452.096 byte, SHA-256 `feb9b635c5e28cae7ded457f1c1f7a92eca32052827218502c2c3ea775b4636a`. `dd` ha riferito `925+1 records in`, `925+1 records out`, 3.880.452.096 byte trasferiti in 220,598432 secondi (17.590.570 byte/s); il conteggio coincide con la dimensione dell'immagine. Il conteggio non è un confronto indipendente con il dispositivo sorgente.
- Clone locale di lavoro dell'immagine: `Build/evidence/OPENHDDLAB-work.img`, stesso numero di byte e stesso SHA-256. Partizione NTFS estratta: `Build/evidence/OPENHDDLAB-partition.img`, 3.876.323.328 byte, SHA-256 `1068e7828751e973f4b7d678a757b58fcfc11aae384f33e7ce46895e6ef51f01`.
- Gli artefatti sono sotto `Build/`, ignorati da Git. I loro hash identificano i file conservati in questo workspace; copiarli altrove richiede ricontrollare gli hash.

## Riscontro della struttura

L'ispezione è stata eseguita sull'immagine di partizione e sui suoi cloni con gli strumenti NTFS-3G 2026.7.7; nessun comando di analisi ha scritto sulla USB originale.

1. La scansione delle allocazioni riferite dai record MFT e dai metadati trova 946.367 cluster totali e 907.961 liberi: 38.406 cluster riferiti come occupati.
2. La lettura del file di metadati `$Bitmap` indica invece 471.241 cluster liberi, ossia 475.126 segnati occupati.
3. La differenza è 436.720 cluster, pari a 1.788.805.120 byte con cluster da 4.096 byte. Sono cluster segnati occupati senza un proprietario trovato dalla scansione degli extent MFT. Ciò concorda con l'errore Windows sulla bitmap e con il calo anomalo di spazio libero.
4. La directory radice non contiene il nome finale interrotto né `.OpenHDD-pending-*`. Il record interrogato per il nome finale non esiste; i record MFT 69–71 non contengono firma `FILE` valida.
5. `ntfsrecover -n -t` non trova operazioni journal da riprodurre: il `$LogFile` risulta pulito e contiene solo record noop/checkpoint. `ntfsfix -n` controlla alcuni metadati di base, ma non è un controllo completo e non smentisce la discrepanza della bitmap.

La causa più probabile è che la copia abbia allocato in anticipo i cluster con `ntfs_attr_truncate_solid()` in [WriteEngine.c](../Sources/NTFSWrite/WriteEngine.c), mentre scollegamento e scritture/cache hanno lasciato `$Bitmap` persistente senza la corrispondente registrazione MFT/directory. Gli esiti combaciano con l'ipotesi, ma **non è una dimostrazione causale completa**: manca un'immagine integrale dello stesso volume immediatamente prima del guasto da confrontare settore per settore e l'avanzamento non prova la persistenza delle scritture. Non si attribuisce quindi ogni cluster senza proprietario con certezza a quella singola chiamata.

## Simulatore di cache e interruzione su immagine

`Tests/offline_image_writer.c` ora può sostituire il solo dispositivo di un'immagine privata con una cache di test. Ogni `pwrite` viene accettata e tenuta in memoria; `pread` vede la vista accettata; `sync` persiste le scritture nel file immagine. La prova può rendere persistenti selettivamente alcune scritture, troncare una scrittura persistita, invertire l'ordine di flush e terminare con `_exit(86)`, che scarta la cache non persistita. Le scritture dichiarate persistite vengono sincronizzate al file immagine. Il trace registra solo numeri di chiamata, offset e dimensioni, mai dati del file.

La suite `Tests/run-offline-write-probe.sh` crea una fixture NTFS da 128 MiB, esegue la preallocazione per un sorgente da 2 MiB, e ripete in modo deterministico questa sequenza: accetta le prime due scritture senza renderle persistenti; rende persistente la terza scrittura (4.095 byte) che in questa fixture colpisce `$Bitmap`; quindi interrompe il processo. Dopo il riavvio simulato, `ntfsinfo -m` riporta 32.138 cluster liberi mentre `ntfscluster -i` trova 32.142 cluster liberi; i record MFT in uso restano 19 e `lost.bin` non compare. `ntfsinfo -m` non trova un restart page; `ntfsrecover -n -t` riferisce che il log file è stato azzerato e non riproduce una transazione. Lo stesso scenario con soli 512 byte della terza scrittura persistiti dà la stessa differenza. È una riproduzione minima e ripetibile di bit di allocazione persistiti senza un file/MFT pubblicato; non replica i 436.720 cluster del volume fisico.

Due controlli aggiuntivi sono passati: una sequenza di flush invertita causa un errore nella verifica finale e non produce `PASS`, ma il file precedente resta leggibile e con hash uguale; una perdita durante il flush termina dopo aver reso persistente un solo elemento e non produce `PASS`. Gli artefatti immagine e trace sono conservati in `Build/evidence/powerloss-sim-20260927/`; i checksum sono in `SHA256SUMS`. Tutti i test rifiutano dispositivi fisici.

Limiti: la cache simulata si collega dopo il mount dell'immagine, usa un fixture singolo e sequenze fisse, non modella cache del controller reale o guasti a livello di settore, e non è stata sottoposta a 1.000 semi. Il file precedente è verificato nel test di flush invertito; la riproduzione bitmap minima parte da una fixture senza file utente precedente. Il simulatore migliora la riproducibilità, ma non prova il recupero Windows e non supera il gate `$LogFile`.

## Gate del journal nativo

### Inventario delle mutazioni

Tracciamento diretto del percorso in `Sources/NTFSWrite/WriteEngine.c` e delle chiamate NTFS-3G:

| Passo OpenHDD | Chiamate | Metadati che possono cambiare | Copertura `$LogFile` verificata |
|---|---|---|---|
| Apertura volume read/write | `ntfs_device_mount(device, 0)` | stato dirty, journal/recovery secondo le opzioni NTFS-3G e lo stato del volume | nessun writer di transazioni collegato al mount |
| Creazione temporaneo | `ntfs_create(root, ...)` | record MFT, `$MFT::$BITMAP`, attributi `FILE_NAME`, indice `$I30` della radice, contatori/link e possibili metadati di sicurezza | nessuna |
| Allocazione anticipata | `ntfs_attr_truncate_solid(data, size)` | runlist e dimensioni dell'attributo `$DATA`, record MFT, `$Bitmap` del volume; possibili record MFT extent | nessuna; è la fase che può allocare molti cluster prima dei dati |
| Scrittura dati | `ntfs_attr_pwrite(...)` | contenuto `$DATA`; a seconda del caso, runlist, dimensioni e record MFT | nessuna |
| Pubblicazione | `ntfs_link(source, root, ...)` | nuovo `FILE_NAME`, link count e indice `$I30` | nessuna; link + sync non forma una transazione NTFS |
| Rimozione temporaneo | `ntfs_delete(...)` | `$I30`, `FILE_NAME`, MFT bitmap, link count e bitmap cluster liberati | nessuna; può lasciare stato parziale distinto dalla pubblicazione |
| Chiusura/unmount | `ntfs_inode_close`, `ntfs_umount`, `fsync` e `DKIOCSYNCHRONIZECACHE` | scrittura differita dei metadati e stato di chiusura | flush ordina/persiste richieste, ma non aggiunge record redo/undo |

La matrice non è una dichiarazione che ogni chiamata tocchi sempre ogni elemento elencato: è l'insieme delle strutture che il protocollo deve coprire anche nei casi di espansione MFT, indici e allocazione. Un log wrapper intorno a `ntfs_attr_pwrite` sarebbe insufficiente perché le funzioni NTFS-3G emettono scritture interne multiple e differite.

### Risultato della verifica sorgenti

La code review di NTFS-3G vendorizzato non ha trovato un writer del journal `$LogFile` che copra le mutazioni usate dal motore:

- `ntfs_attr_truncate_solid`, `ntfs_attr_pwrite`, `ntfs_create`, hard link, aggiornamenti MFT, bitmap e indici modificano strutture NTFS attraverso normali scritture della libreria; il motore non inserisce tali modifiche in transazioni LFS NTFS.
- `libntfs-3g/logfile.c` contiene validazione e lettura del formato. `ntfsrecover` può interpretare e riprodurre alcune azioni già presenti e commesse nel journal: non genera transazioni per il writer OpenHDD.
- `libntfs-3g/volume.c` controlla `$LogFile` sui mount read/write. Con recovery abilitato il percorso può chiamare `ntfs_logfile_reset`, che marca il journal vuoto; il commento upstream avverte che possono restare LSN MFT da sistemare. Azzerare il journal non equivale a registrare una transazione.
- Nell'immagine acquisita il journal non contiene record di redo/undo relativi alle allocazioni orfane. Windows non ha quindi una transazione NTFS da riprodurre per ripristinare `$Bitmap`.

La documentazione ufficiale Linux NTFS3 distingue esplicitamente il replay nativo del journal dal journaling completo; indica il journaling completo come lavoro non ancora completato. È evidenza che un driver con replay non basta a dimostrare un protocollo writer recuperabile, non prova che ogni implementazione NTFS esistente abbia lo stesso limite ([documentazione NTFS3 del kernel](https://docs.kernel.org/filesystems/ntfs3.html)).

È stato esaminato anche `rust-fs-ntfs`, candidato Rust con ABI C utilizzabile da Swift. Il suo README dichiara codice ancora pre-1.0 e recovery basato su rilevamento/azzeramento di `$LogFile`, non un writer di transazioni native. I test dichiarati su volumi nuovi e `chkdsk /scan` non dimostrano recupero di una copia interrotta. Non è stato aggiunto al progetto ([stato e limiti dichiarati dal progetto](https://github.com/christhomas/rust-fs-ntfs)).

Non esiste ancora una specifica verificata che copra redo/undo, ordinamento e flush, commit, checkpoint, riutilizzo del log, modifiche multi-record e recupero interrotto. Senza quella specifica non è possibile dimostrare quando ogni modifica diventa recuperabile, quali immagini di settore Windows debba riprodurre, né come un recovery interrotto riprenda in sicurezza. In mancanza di questa copertura, una transazione costruita attorno alle API NTFS-3G esistenti sarebbe solo un protocollo privato, non il recupero standard Windows richiesto.

**Gate obbligatorio non superato.** Non iniziare il prototipo di scrittura transazionale né riabilitare copie fisiche. Prossimo lavoro utile: cercare una specifica NTFS/LFS primaria e una libreria writer mantenuta che implementi il formato; prima di adottarla, auditare codice e licenza e dimostrare sulle immagini recupero Windows senza CHKDSK. Se non si trova una base documentata, mantenere il rapporto di impossibilità e l'app in sola lettura. Questo è un blocco della combinazione tecnica verificata, non una prova che un writer NTFS journal-aware sia irrealizzabile in assoluto.

## Stato operativo e prossima decisione

- `OpenHDDCopy --disk` ora termina prima di qualunque accesso al dispositivo; `oh_copy_new_file` rifiuta anche chiamate dirette marcate come dispositivo e descrittori che non sono file regolari. `Tests/run-direct-copy-probe.sh` ha verificato questi blocchi e le copie su immagini private. Nessuna nuova scrittura fisica è stata tentata.
- Il volume conserva i cinque file verificati ma ha una bitmap incoerente. Non copiare altri dati su di esso. Il marcatore locale OpenHDD continua a bloccare il tool su questo Mac.
- Non eseguire `chkdsk /scan`, `chkdsk /f`, `ntfsfix`, formattazione o altre correzioni prima di avere deciso se conservare il disco nello stato corrente. L'immagine è la copia forense non modificata disponibile per ulteriori analisi.
- Le modifiche a interfaccia e copia sopra un protocollo journal validato (passi 3–5 del piano) non partono. Per usare ancora questa USB, la via prudente è conservare prima l'immagine e i file, poi far riparare/formattare il volume da Windows soltanto dopo aver scelto esplicitamente di rinunciare allo stato forense originale.
- Per ottenere scrittura sicura dal Mac resta da procurare o sviluppare un motore che documenti e generi transazioni `$LogFile` compatibili, copra ogni mutazione, e superi recuperi Windows su immagini interrompendo anche il recupero stesso. Fino ad allora: lettura NTFS sul Mac; scrittura tramite Windows o su un formato supportato nativamente dal Mac.
