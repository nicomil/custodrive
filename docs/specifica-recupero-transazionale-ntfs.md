# OpenHDD — Specifica di implementazione del recupero transazionale NTFS

Versione: **0.1 — specifica di ricerca e criteri di accettazione**  
Data: **27 settembre 2026**  
Stato: **nessun gate transazionale superato; scritture fisiche bloccate**

## 1. Scopo e uso del documento

Questo documento guida l'implementazione di un prototipo che scrive transazioni nel journal nativo NTFS `$LogFile`, recuperabili dal driver Windows usando esclusivamente informazioni presenti nel volume. Il risultato immediato richiesto è una dimostrazione ripetibile di compatibilità, non l'abilitazione della scrittura nell'app.

La specifica distingue requisiti da fatti verificati. Non contiene ancora una descrizione binaria completa e validata del protocollo NTFS/LFS: produrla è un'attività obbligatoria, con un proprio gate. Non inventare campi, codici operazione o regole di recupero per colmare lacune. Una lacuna necessaria impedisce di eseguire quel percorso di scrittura.

Le parole **DEVE**, **NON DEVE** e **BLOCCA** identificano requisiti obbligatori. Una prova mancante non equivale a una prova superata. Ogni gate ha quattro esiti: `NON_ESEGUITO`, `PASS`, `FAIL`, `INCONCLUDENTE`; soltanto `PASS` permette l'avanzamento previsto.

Questa specifica aggiorna il percorso futuro indicato nel [rapporto forense](analisi-guasto-bitmap-ntfs-2026-09-27.md): è consentito progettare e poi costruire un writer sperimentale sulle sole immagini secondo i gate qui definiti. Il precedente invito a non iniziare alcun prototipo non costituisce una dimostrazione di impossibilità assoluta. Restano invariati i risultati forensi e il blocco dei dispositivi fisici.

### 1.1 Vincoli del prodotto

- Uso personale, Mac Apple Silicon da M1, obiettivo runtime macOS 15.4 e successivi.
- Nessun abbonamento, VM o driver kernel richiesto per l'uso ordinario.
- Windows disponibile come sistema esterno di collaudo e recupero eccezionale.
- Nessun file o database sul Mac indispensabile per recuperare il volume.
- Primo prodotto limitato a nuovi file nella radice, nomi ASCII validi, nessuna sovrascrittura.
- Nessuna riparazione automatica, formattazione o cancellazione automatica di temporanei dopo un errore.
- Nessuna promessa di integrità assoluta su hardware guasto o che non rispetti la sincronizzazione.

### 1.2 Risultati distinti

| Risultato | Cosa dimostra | Cosa non autorizza |
|---|---|---|
| Specifica binaria verificata | Le operazioni limitate hanno una descrizione implementabile e riscontri | Scritture sulla USB |
| Recupero Windows su immagini | Il sottoinsieme implementato è recuperabile nei casi provati | Uso su dati importanti o nell'app |
| Collaudo completo del protocollo | Copertura documentata di errori, riuso del log e recupero interrotto | Supporto di geometrie o funzioni non provate |
| Rilascio limitato | Uso nelle configurazioni effettivamente validate | Garanzie universali su qualsiasi USB |

## 2. Base osservata e componenti esistenti

Riferimento Git al momento della stesura: `4fcb95055541e66ec9b91a05fe92c6279de7a642`, **con modifiche locali non committate**. Il commit da solo non identifica il codice corrente: ogni campagna DEVE conservare anche patch, file non tracciati pertinenti, opzioni di build e hash del binario.

| Componente presente | Ruolo attuale | Indicazione per l'implementazione |
|---|---|---|
| `Sources/NTFSWrite/WriteEngine.c` | Copia sperimentale NTFS-3G; preallocazione, verifica, hard link e rimozione temporaneo | Conservare come riferimento/controllo negativo; non dichiararlo transazionale |
| `Sources/NTFSWrite/WriteEngine.h` | API con codice errore e numero di fase | Evolvere solo dopo la prima prova del protocollo; contratto futuro nella sezione 11 |
| `Sources/NTFSWrite/OpenHDDCopy.c` | CLI, identità, esclusività, quarantena e diagnostica | Conservare `--check-disk` e il blocco `physical_ntfs_writes_validated = 0` |
| `Sources/NTFSBridge/OpenHDDNTFS.c` | Lettura tramite NTFS-3G | Riutilizzare per riscontri in lettura; non è indipendente dalla libreria NTFS-3G |
| `Tests/offline_image_writer.c` | Writer di immagini con cache simulata | Riutilizzare il modello di guasto; collegarlo prima della prima possibile modifica |
| `Tests/run-offline-write-probe.sh` | Prove del precedente writer | Mantenere la regressione; preservare gli artefatti falliti nella nuova suite |
| `Tests/run-direct-copy-probe.sh`, `Tests/quarantine_probe.c` | Errori e blocchi della CLI/API | Devono continuare a verificare il rifiuto dei dispositivi |
| `vendor/ntfs-3g-2026.7.7` | Lettore, primitive NTFS, diagnostica e replay | Lettura/replay non dimostrano capacità di generare transazioni Windows |

La prova reale di scollegamento ha lasciato una bitmap incoerente; i cinque file precedenti avevano ancora gli hash attesi secondo le verifiche riferite dall'utente. Il simulatore riproduce una classe equivalente di incoerenza, non la sequenza fisica esatta. Dettagli, conteggi e provenienza restano nel rapporto forense, che non va riscritto come se il nuovo protocollo fosse già disponibile.

### 2.1 Reperti da preservare

| Reperto | Dimensione | SHA-256 registrato |
|---|---:|---|
| `Build/evidence/OPENHDDLAB-20260927.img` | 3.880.452.096 byte | `feb9b635c5e28cae7ded457f1c1f7a92eca32052827218502c2c3ea775b4636a` |
| `Build/evidence/OPENHDDLAB-partition.img` | 3.876.323.328 byte | `1068e7828751e973f4b7d678a757b58fcfc11aae384f33e7ce46895e6ef51f01` |

Questi valori sono ripresi dall'acquisizione documentata, non ricalcolati durante la stesura. Prima di usare un reperto, verificarne dimensione e hash. Lavorare esclusivamente su copie nuove; originali e immagini di crash non devono essere montati in scrittura. Una baseline nuova e sana deve essere preparata separatamente dall'immagine danneggiata.

## 3. Proprietà obbligatorie

| ID | Proprietà | Evidenza richiesta |
|---|---|---|
| R01 | Nessuna modifica fuori dal volume/immagine selezionato | Controlli sul descrittore, limiti degli offset, sentinelle attorno alla partizione |
| R02 | Nessuna modifica ai dati dei file preesistenti | Inventario, dimensioni e SHA-256 prima/dopo; verifica degli attributi pertinenti |
| R03 | Coerenza dell'allocazione dopo recupero | Nessun cluster perso, riferito ma libero, o condiviso illegalmente; controllo MFT e indici |
| R04 | Nessun falso successo | Risultato di copia completata solo dopo tutte le condizioni previste |
| R05 | Recupero standard autonomo | Windows recupera senza eseguibile OpenHDD, sidecar o registro locale |
| R06 | Copertura completa dei metadati modificati | Ogni scrittura riconducibile a un'operazione del protocollo e alle sue dipendenze |
| R07 | Dati persistenti prima di renderli validi | Fault injection tra scrittura dati, sync, aggiornamento dimensioni e commit |
| R08 | Pubblicazione atomica del nome finale | Nome finale assente oppure associato all'intero contenuto verificato |
| R09 | Rifiuto sicuro dei casi non supportati | Zero scritture al target e hash immagine invariato |
| R10 | Recupero riavviabile | Arresto durante il recupero seguito da recupero riuscito, senza riparazioni |
| R11 | Nessuna dipendenza dalla cache del processo | Verifica dopo chiusura/riapertura e sul sistema Windows indipendente |
| R12 | Stato incerto conservato | Nessuna nuova copia, pulizia o rimozione automatica del blocco |

I metadati che devono cambiare legittimamente, per esempio l'indice della radice, non devono essere confrontati come se l'intero volume dovesse restare identico. Ogni differenza deve essere classificata. Dopo il montaggio Windows sono possibili modifiche di sistema: confrontarle anche con un controllo sano montato nello stesso ambiente, senza usarlo per giustificare differenze arbitrarie.

## 4. Perimetro iniziale del laboratorio

Il primo profilo supportato DEVE essere ricavato da immagini realmente formattate da Windows e registrato in un manifest. Registrare versione NTFS, versione LFS, settore logico, cluster, record MFT, pagine del log, dimensioni e posizione della partizione. Non assumere che NTFS 3.1 determini da solo il formato del journal.

Obiettivo iniziale: settore logico 512 byte, cluster 4 KiB, una partizione NTFS non cifrata, sana e smontata. Si tratta di una scelta del laboratorio da verificare sulle fixture, non di supporto già implementato. Se il formato journal osservato non è descrivibile con sufficiente certezza, fermare il writer e completare la ricerca.

Il prototipo iniziale può rifiutare MFT o indice da espandere, frammentazione non gestita, attributi estesi non supportati, compressione, sparse, cifratura, reparse point, alternate data stream, transazioni attive o journal senza spazio sufficiente. I rifiuti devono avvenire prima della prima scrittura. Il controllo deve considerare anche metadati ereditati dalla radice e caratteristiche del volume che potrebbero richiedere ulteriori aggiornamenti.

Non richiedere che ogni file preesistente usi soltanto le funzioni supportate dal writer: il validatore deve però saperne enumerare l'allocazione. Se non sa farlo, non può certificare R03 e la fixture non è valida per il gate.

Utilizzare almeno due immagini formattate separatamente, con posizione dei metadati differente e file sentinella residenti/non residenti. Nessun offset MFT, bitmap, log o directory può essere fissato nel codice in base a una singola fixture.

## 5. Gate G0 — evidenze, isolamento e validità del banco

Prima del nuovo writer:

1. Verificare i reperti, generare copie di lavoro e un inventario immutabile degli originali.
2. Conservare il caso negativo del vecchio motore che lascia `$Bitmap` incoerente.
3. Preparare immagini sane Windows e misurare i cambiamenti di un semplice ciclo mount/unmount senza OpenHDD.
4. Provare il trasporto immagine tra Mac e Windows e il ritorno, con hash verificati a ogni passaggio.
5. Dimostrare che un errore nel laboratorio produce `FAIL` o `INCONCLUDENTE`, mai `PASS`.
6. Verificare che il banco rifiuti device, symlink, immagini già collegate e descrittori non regolari. Un file regolare da solo non prova che nessun sistema lo abbia montato.

Il runner deve creare una directory privata e un'immagine sacrificabile nuova per ogni caso, aprirla senza seguire symlink, verificarne identità prima/dopo l'apertura e operare sul descrittore verificato. Rifiutare hard link inattesi e alias tra sorgente e destinazione. Nessun reopen mutabile tramite percorso dopo la validazione. L'esclusività richiede anche controlli sullo stato di collegamento dell'immagine e un contratto del runner; `O_EXCL` su un file esistente non basta.

**Uscita G0:** manifest di baseline, controllo sano, controllo negativo, prove di isolamento e procedura Windows eseguibile. La perdita o alterazione di un originale BLOCCA la campagna.

## 6. Gate G1 — specifica binaria del sottoinsieme NTFS/LFS

### 6.1 Documento di protocollo da produrre

Creare `docs/protocollo-logfile-ntfs.md` durante l'implementazione. Per ogni campo o regola registrare: fonte e revisione, offset, ampiezza, endianess, allineamento, validazione, fixture di riscontro e limiti conosciuti. Separare «documentato», «osservato» e «ipotesi». Un'ipotesi su un campo indispensabile non passa G1.

La specifica deve coprire, per la versione selezionata:

- Restart pages, selezione della copia valida, restart area e record del client NTFS.
- Pagine dei record, firme, update sequence/fixup e rilevamento delle pagine incomplete.
- LSN: codifica, ordinamento, collegamenti tra record e relazione con gli LSN nei metadati.
- Identità delle transazioni, record di inizio/fine secondo il formato effettivo, catene undo e stato del commit.
- Operazioni native redo/undo necessarie, riferimenti agli attributi, VCN/LCN e pagine bersaglio.
- Tabelle richieste dal recupero: transazioni, attributi aperti, pagine modificate e dati di restart pertinenti.
- Checkpoint, recuperabilità dei record e condizione che consente il riutilizzo del log.
- Ripresa di undo/redo interrotti e record di compensazione, se previsti dal protocollo scelto.
- Comportamento a record diviso tra pagine, fine del log, copie ridondanti e wrap. Se escluso dal primo sottoinsieme, rifiuto preventivo dimostrato.

Le strutture in `vendor/ntfs-3g-2026.7.7/include/ntfs-3g/logfile.h`, `libntfs-3g/logfile.c` e `ntfsprogs/ntfsrecover.c` sono materiale da auditare. Non trasformare commenti incerti in regole certe. La documentazione del formato prodotta da Linux-NTFS è una fonte di ricerca degli autori, non una specifica Microsoft completa delle versioni moderne. [Formato Linux-NTFS](https://flatcap.github.io/linux-ntfs/ntfs/files/logfile.html)

### 6.2 Matrice delle mutazioni

Per ogni operazione concreta il documento deve completare questa matrice:

| Struttura | Possibili cambiamenti | Prova richiesta |
|---|---|---|
| `$Bitmap` | Allocazione/liberazione dei cluster | Undo/redo con recupero esatto dei bit coinvolti |
| `$MFT::$BITMAP` | Occupazione dei record | Coerenza tra bit e record in uso |
| Record `$MFT` | Attributi, runlist, dimensioni, riferimenti, link e LSN | Record valido prima/dopo; fixup e riferimenti corretti |
| Indice radice `$I30` | Inserimento, pubblicazione e rimozione del nome temporaneo | Indice valido e corrispondenza con `FILE_NAME` |
| Record/bitmap dell'indice | Allocazione o split, se supportati | Copertura completa oppure rifiuto prima della scrittura |
| Metadati di sicurezza e altri file di sistema | Ereditarietà/riferimenti e aggiornamenti obbligatori | Riutilizzo valido o transazioni dedicate; nessuna omissione implicita |
| `$Volume` e `$LogFile` | Stato volume, restart, commit e checkpoint | Transizioni recuperabili anche durante apertura/chiusura |
| `$MFTMirr` | Replica dei record interessati, se applicabile | Coerenza secondo le regole del formato |

Per ogni riga aggiungere l'opcode nativo effettivo, payload prima/dopo, dipendenze, prova Windows e motivo di eventuale non applicabilità. Un generico salvataggio «offset + vecchi byte» non sostituisce un'operazione NTFS riconosciuta da Windows.

### 6.3 Acquisizione di esempi Windows

Raccogliere esempi del journal generati da Windows per operazioni equivalenti, con procedura e versione registrate. Verificare che i record pertinenti siano ancora disponibili: un'immagine smontata correttamente può non conservare una transazione attiva utile. Non assumere che copiare `$LogFile` da un volume live produca una cattura coerente.

Se serve osservare una transazione attiva, definire prima un metodo affidabile di acquisizione o tracciamento del dispositivo virtuale. La disponibilità di questo metodo è una dipendenza aperta. Campioni ambigui possono guidare la ricerca ma non certificano il protocollo.

**Uscita G1:** specifica binaria completa per l'operazione limitata, esempi decodificati, round-trip di serializzazione e matrice senza modifiche scoperte. Solo allora iniziare il writer di quella operazione. I parser di ricerca e i controlli in lettura possono essere sviluppati prima.

## 7. Writer sperimentale: contratto di persistenza

### 7.1 Architettura minima

Separare il nuovo esperimento dal vecchio percorso NTFS-3G di scrittura. Proposta di collocazione, **file non ancora esistenti**:

| File previsto | Responsabilità |
|---|---|
| `Tests/ntfs_journal_probe.c` | Parser/serializzatore limitato e una transazione su immagine; rifiuto dispositivi |
| `Tests/run-journal-probe.sh` | Fixture, campagne, isolamento, raccolta risultati e conservazione artefatti |
| `Tests/windows/verify-journal-recovery.ps1` | Identità VHD, recupero Windows, CHKDSK, hash e rapporto strutturato |
| `docs/protocollo-logfile-ntfs.md` | Formato verificato, operazioni e dipendenze di persistenza |

Riutilizzare il banco esistente dove possibile. Estrarre il simulatore in un modulo comune solo quando serva a entrambi i runner. Non introdurre un nuovo framework o una seconda libreria filesystem completa.

Ogni scrittura del prototipo passa per un unico punto di I/O verificabile. Registrare struttura bersaglio, operazione, transazione e dipendenza dal log. Non chiamare un mount NTFS-3G read/write che possa mutare dirty bit o journal fuori dal protocollo. La lettura tramite libreria deve restare forense/read-only. Il test deve coprire anche apertura, gestione errori e chiusura.

### 7.2 Regole astratte, da tradurre nel formato G1

1. Calcolare il piano completo dell'operazione e le risorse necessarie prima della prima scrittura: spazio dati, record MFT, indice e log.
2. Rendere persistenti le informazioni native sufficienti al recupero **prima** che possano persistere modifiche ai metadati dipendenti.
3. Scrivere e sincronizzare i dati prima di rendere persistenti dimensioni valide o una pubblicazione che li renda leggibili come completi.
4. Rendere persistente il commit solo quando tutte le dipendenze richieste sono soddisfatte. Un ritorno dalla scrittura del record non equivale a persistenza del commit.
5. Conservare record necessari a undo/redo fino al checkpoint che ne consente il riuso. Non azzerare `$LogFile` per far apparire il volume pulito.
6. Una sincronizzazione fallita lascia la persistenza sconosciuta. Non assumere né rollback né commit; interrompere e richiedere recupero.

Queste sono proprietà da soddisfare, non una sequenza binaria pronta da implementare. Ordine preciso tra record, pagine e restart deve derivare da G1. Non assumere atomicità di una pagina da 4 KiB. Dichiarare il modello di atomicità del settore e provare scritture parziali per le strutture protette dal formato.

### 7.3 Prima operazione utile

Prima verificare singole primitive di undo/redo; poi creare un file nuovo non residente, con dati sintetici noti, in una radice che non richieda espansione. Il caso deve modificare realmente `$Bitmap`, MFT e indice. Un file vuoto o residente non basta a superare il gate di fattibilità.

Per questo esperimento limitato è ammessa una transazione di creazione con nome sintetico finale, purché il contenuto sia persistente prima del commit e il risultato recuperato sia assente oppure completo. Questo non sostituisce il flusso temporaneo/verifica/rinomina del prodotto descritto nella sezione 11.

## 8. Simulazione di perdita di alimentazione

Il dispositivo simulato deve distinguere tre eventi: richiesta emessa, scrittura accettata, byte persistiti. Le letture del processo possono vedere la cache; le immagini dopo il crash devono contenere soltanto ciò che il modello dichiara persistito.

### 8.1 Semantica obbligatoria

- Installare la simulazione prima della prima possibile scrittura, incluse apertura e chiusura.
- Una sincronizzazione riuscita rende persistenti tutte le scritture precedenti secondo il contratto del backend.
- Prima della sincronizzazione e durante una sincronizzazione interrotta, ammettere sottoinsiemi e riordinamenti compatibili con il modello dichiarato.
- Definire espressamente gli ordinamenti per scritture sovrapposte: un flush riuscito non deve lasciare una versione vecchia sopra una nuova a causa del simulatore.
- Iniettare I/O brevi, errori dopo un prefisso scritto, zero-byte progress, `EINTR`, errori permanenti e sync fallita. I retry devono essere limitati e non duplicare effetti logici.
- Simulare perdita della cache separatamente dall'arresto del processo. Un `kill` con page cache del sistema ancora viva non rappresenta uno spegnimento.
- L'esaurimento di memoria del simulatore, disco host pieno o trace incompleto invalidano la prova: non sono crash NTFS superati.
- Dopo il crash, non eseguire destructor o chiusure del writer che potrebbero completare le scritture.

La cache attuale ha un limite di 256 MiB. Per campagne grandi utilizzare un deposito privato separato per lo stato volatile oppure un modello limitato verificato; i dati nel deposito non devono essere copiati nella vista persistita dopo il crash. Non aumentare il limite senza misurare il consumo.

### 8.2 Campagne

| Campagna | Copertura minima |
|---|---|
| Deterministica piccola | Arresto prima/dopo ogni scrittura e ogni sync del protocollo; tagli dentro scritture composte; undo e redo necessari |
| Riordinamento | Sottoinsiemi entro ogni intervallo tra barriere, dipendenze del log, sovrapposizioni e pagine parziali |
| Riproducibilità | Stessa baseline, stesso piano/seme e stesso binario producono lo stesso hash di crash |
| Grande | Almeno 1.000 sequenze con semi e algoritmo registrati, dopo G2; conteggio per famiglia di guasto |
| Parser | Lunghezze fuori limite, overflow, LSN incoerenti, fixup errato, pagine troncate e versioni sconosciute |

Il numero di semi non sostituisce la copertura dei punti critici. Un esito `SKIP` o un caso non raggiunto non conta come successo. Il rapporto elenca prove previste, raggiunte, fallite e inconcludenti.

## 9. Windows come verificatore esterno

### 9.1 Trasporto e isolamento

Usare VHD supportati dagli strumenti nativi Windows; il montaggio non richiede una VM. `Mount-DiskImage` rende l'immagine disponibile come disco e richiede privilegi amministrativi per i VHD. [Documentazione Microsoft](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage)

Preferire inizialmente VHD a dimensione fissa creati da Windows. Il runner Mac deve conoscere e verificare contenitore, offset della partizione e limiti del volume; un VHD non è automaticamente una raw partition. Preservare footer e strutture esterne; rifiutare VHD dinamici/VHDX finché non esiste un adattatore verificato. Verificare il round-trip senza modifiche prima di introdurre il writer.

Ogni prova Windows usa una copia fresca dell'immagine di crash. L'originale non viene collegato. Risolvere disco e volume dall'associazione con l'immagine montata; non fidarsi di una lettera ricordata. Lo script deve rifiutare disco di sistema, destinazioni ambigue e immagini già collegate.

Nessun comando di formattazione o riparazione appartiene allo script di verifica. Non eseguire `chkdsk /f`, `/r`, `/scan`, `ntfsfix`, replay OpenHDD o replay NTFS-3G sulla copia destinata al gate.

### 9.2 Escludere il falso positivo da riparazione automatica

Windows può correggere NTFS senza invocare CHKDSK. `fsutil repair` permette di interrogare lo stato, disabilitare self-healing e leggere i registri delle corruzioni. Questo è distinto dal normale recupero del journal. [Microsoft: fsutil repair](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-repair)

Il laboratorio DEVE dimostrare che self-healing non ha mascherato il guasto **a partire dal primo accesso Windows che può recuperare il volume**. Disabilitarlo dopo il mount è troppo tardi. La documentazione citata non dimostra, da sola, che una configurazione applicata alla baseline rimanga efficace attraverso detach, trasferimento e nuovo mount.

Prima di G2 occorre quindi validare una configurazione persistente/pre-mount per quel preciso ambiente, oppure un'osservazione capace di distinguere senza ambiguità replay e riparazione dall'inizio. Conservare stato, registri, versione Windows e prova di controllo. Se ciò non è possibile, l'esito resta `INCONCLUDENTE`, anche con CHKDSK pulito. Non modificare impostazioni globali del computer principale né provocare crash del sistema per aggirare questo requisito.

### 9.3 Procedura per ogni caso

1. Verificare hash e dimensione dell'artefatto ricevuto; preservarne una copia intatta.
2. Verificare G0 e la configurazione che distingue replay da riparazione.
3. Montare in scrittura soltanto la copia di lavoro: il normale recupero deve poter persistere le proprie modifiche.
4. Acquisire esito mount, timeout, eventi e registri pertinenti. Annullare proposte di riparazione.
5. Eseguire `chkdsk LETTERA:` senza opzioni di riparazione, con volume quieto; salvare output completo e codice di uscita. Un volume occupato o un controllo incompleto è inconcludente.
6. Enumerare file sintetici, dimensioni e SHA-256 con PowerShell; verificare anche sentinelle e nomi temporanei. Per i file vuoti usare `Get-FileHash`, non dipendere dall'esito storico di `certutil`.
7. Smontare normalmente, conservare l'immagine recuperata e il suo hash.
8. Analizzare offline la struttura recuperata: bitmap, runlist, record in uso, riferimenti e indici. Il controllo deve comprendere allocazioni dei file di sistema; il semplice confronto di due contatori di spazio libero non basta.
9. Confrontare con lo stato atteso del caso e il controllo sano. Associare ciascuna differenza al recupero o a una modifica Windows spiegata.

NTFS-3G può fornire un secondo riscontro, ma un lettore che usa la stessa libreria del writer non costituisce da solo un verificatore indipendente. Windows, controllo strutturale offline e manifest atteso devono fornire evidenze concordanti.

### 9.4 Controlli di causalità

Preparare coppie di immagini con identici metadati incompleti e log differenti. Il caso positivo contiene i record indispensabili; il negativo li rende indisponibili secondo una mutazione documentata. Considerare copie ridondanti e pagine alternative: cancellare un solo record duplicato potrebbe non eliminare le informazioni.

Il controllo non deve imporre che qualsiasi journal alterato renda il volume illeggibile. Deve invece dimostrare, in un caso costruito per richiedere undo o redo, che lo stesso recupero non è ottenuto senza le informazioni necessarie. Se entrambe le immagini arrivano allo stesso stato e non è spiegato perché, non è provata la causalità: `INCONCLUDENTE`.

## 10. Gate G2 — fattibilità del recupero nativo

Prerequisiti: G0 e G1 passati, writer limitato, simulatore verificato e procedura Windows non ambigua.

| Caso | Stato persistito al crash | Stato richiesto dopo il recupero Windows |
|---|---|---|
| F0 | Nessuna modifica emessa | Baseline invariata, salvo modifiche Windows del controllo sano |
| F1 | Log preparato, nessun metadato applicato, nessun commit persistente | Operazione non pubblicata, nessuna allocazione persa |
| F2 | Metadati applicati in parte, undo disponibile, nessun commit persistente | Operazione annullata; file precedente e allocazione ripristinati |
| F3 | Commit persistente, dati persistenti, metadati applicati in parte | Redo completo; nuovo file con dimensione e hash attesi |
| F4 | Metadati completi, checkpoint incompleto | Stato coerente; recupero ripetibile senza duplicazioni |
| F5 | Risposta di sync perduta o errore al confine del commit | Stato precedente oppure nuovo secondo il commit realmente persistito; mai successo del processo interrotto |
| F6 | Coppie positive/negative della sezione 9.4 | Recupero attribuibile al journal, non a riparazioni o dati già completi |

Per F1/F2 l'annullamento riguarda la singola transazione non commessa. Nel futuro flusso a più transazioni, i segmenti già commessi del temporaneo possono restare: non si richiede di annullare un intero trasferimento già parzialmente confermato.

G2 passa soltanto se tutti i casi richiesti passano sulle due baseline indipendenti, con almeno un file non residente, vecchi file integri, struttura valida e nessun intervento riparativo. L'immagine di ciascun caso deve poter essere riprodotta e recuperata su Windows senza fornire registri OpenHDD.

**G2 non autorizza scritture fisiche né il pulsante nell'app.** Un singolo `FAIL` strutturale riapre G1/protocollo. Un caso inconcludente richiede correggere il banco o acquisire la prova mancante; non può essere sostituito da ulteriori copie normali.

## 11. Dopo G2: copia a transazioni limitate

Solo dopo G2 portare il protocollo nel motore ed evolvere l'API. Il modello seguente è un contratto previsto, non una descrizione del codice corrente.

### 11.1 Stati dell'operazione

`VALIDAZIONE → TEMPORANEO → TRASFERIMENTO → VERIFICA_TEMPORANEO → PUBBLICAZIONE → VERIFICA_FINALE → CHIUSURA → ESPULSIONE → COMPLETATO`

- **VALIDAZIONE:** identità, esclusività, sorgente stabile, volume sano, risorse e caratteristiche supportate; zero scritture in caso di rifiuto.
- **TEMPORANEO:** creazione con transazione recuperabile; collisioni rifiutate, nessuna sostituzione.
- **TRASFERIMENTO:** allocazione e avanzamento in transazioni limitate, con dimensione massima motivata dal budget del log; nessuna preallocazione proporzionale all'intero file.
- **VERIFICA_TEMPORANEO:** sincronizzazione, chiusura, riapertura in lettura e confronto dimensione/SHA-256. La sorgente deve essere stabilizzata, per esempio in una copia privata verificata sul Mac; i soli timestamp non dimostrano immutabilità durante la copia. Tale copia non è dichiarata salvata su NTFS.
- **PUBBLICAZIONE:** rinomina nativa recuperabile, senza sovrascrittura. Non riutilizzare automaticamente la sequenza hard link più cancellazione del vecchio motore.
- **VERIFICA_FINALE:** nome finale, identità, dimensione e hash corretti; temporaneo secondo il contratto di rinomina.
- **CHIUSURA/ESPULSIONE:** metadati e stato log persistenti, chiusura riuscita, espulsione normale. Un errore qui impedisce `COMPLETATO` anche se il contenuto era già verificato.

Prima della pubblicazione, un guasto può lasciare un temporaneo coerente con il solo prefisso confermato. Dopo il commit della rinomina può restare il nome finale completo. Non pubblicare un prefisso come copia riuscita e non cancellare automaticamente temporanei dopo errori.

### 11.2 Risultato strutturato

Contratto da introdurre in `WriteEngine.h`, senza fissare adesso una ABI definitiva:

| Campo | Valori / significato |
|---|---|
| `outcome` | `REFUSED`, `INTERRUPTED`, `RECOVERY_REQUIRED`, `COMPLETED` |
| `phase` | Uno degli stati della sezione 11.1 |
| `error_domain`, `error_code` | Errore originario preservato; non ridotto al solo numero di fase |
| `writes_started` | Vero prima della prima richiesta di scrittura al target, anche se poi fallisce |
| `verification_completed` | Verifica finale indipendente della copia completata |
| `commit_state` | `NOT_COMMITTED`, `COMMITTED`, `UNKNOWN` |
| `recovery_required` | Vero quando il volume richiede recupero/controllo prima di ulteriori copie |
| `eject_state` | `NOT_ATTEMPTED`, `SUCCEEDED`, `FAILED`, `NOT_APPLICABLE` |

`COMPLETED` richiede tutte le verifiche e l'espulsione per un dispositivo fisico. Il runner immagini può riportare completamento dell'esperimento con `NOT_APPLICABLE`, ma non deve stamparlo come disco espulso. In caso di arresto improvviso potrebbe non esistere alcun risultato: il supervisore deve trattare output troncato o mancante come esito incerto.

`REFUSED` implica zero richieste di scrittura; dopo una richiesta fallita non è lecito usare questo esito per sostenere che nulla sia cambiato. Errori durante undo, close o eject non devono nascondere l'errore originario.

### 11.3 Quarantena e riabilitazione

Il marcatore sul Mac resta una protezione aggiuntiva. La sua assenza non prova che il volume sia sano; il recupero deve funzionare su un altro computer senza quel marcatore. Dopo un guasto bloccare nuove copie, mostrare «Volume da recuperare» e richiedere controllo Windows documentato, stato coerente e nuovo preflight prima di una riabilitazione esplicita.

Gli hash corretti dei soli file visibili non sbloccano il volume. Non cancellare marker perché Windows ha assegnato una lettera o perché il dirty bit risulta pulito.

## 12. Gate G3 — completezza del protocollo e recupero interrotto

Estendere progressivamente il sottoinsieme; ogni nuova mutazione deve aggiornare G1 e ripassare G2. Coprire:

- File da 0 e 1 byte, soglia residente/non residente, settore ±1, cluster ±1, blocco di copia ±1, file grandi e contenuti Unicode con nomi ASCII.
- Duplicati, collisioni temporaneo/finale, nomi riservati, sorgente cambiata, spazio dati o metadati insufficiente e journal insufficiente.
- Volume dirty, ibernato, malformato, versione sconosciuta, identità cambiata e accesso non esclusivo: rifiuto prima della scrittura.
- MFT e directory prossime all'espansione; espansione transazionale se supportata, altrimenti rifiuto preventivo dimostrato.
- Log quasi pieno, checkpoint, riutilizzo, wrap e più trasferimenti successivi sullo stesso volume.
- Errori e interruzioni durante creazione, estensione, verifica, rinomina, chiusura e recupero.
- Almeno 1.000 sequenze riproducibili per la campagna grande, oltre ai tagli deterministici critici.

**Interrompere il recupero è una prova separata.** Montare un VHD da PowerShell non offre, da solo, controllo su ogni I/O eseguito dal driver Windows. Occorre un banco capace di intercettare/persistire selettivamente gli I/O del disco di test durante il replay, oppure una procedura fisica controllata con copertura dichiarata. Se serve strumentazione aggiuntiva di laboratorio, documentarne privilegi e impatto prima di adottarla; non diventa una dipendenza del prodotto.

Finché tale banco non è disponibile, R10 e G3 restano non superati. Un semplice secondo mount dopo un recupero completato dimostra idempotenza finale, non resistenza all'interruzione del recupero. Non spegnere il computer personale per sostituire questa prova.

## 13. Gate G4/G5 — hardware e rilascio limitato

### G4: collaudo fisico controllato

Prerequisiti: G0–G3 passati e rapporto collegato alla versione del binario. Preparare una build di collaudo distinta; la build ordinaria e l'app restano bloccate. L'abilitazione sperimentale deve essere esplicita, verificabile e limitata ai dispositivi sacrificabili identificati nella sessione, non ottenuta con un generico flag ambiente in produzione.

Provare almeno due dispositivi sacrificabili con controller differenti; escludere la Kingston ritirata per errori I/O. Prima di ogni prova controllare identità, capacità, volume, stato NTFS, esclusività e backup dei dati di controllo. Un nome `disk4s1` non costituisce identità persistente.

Provare copia normale, arresto del processo e scollegamento USB in fasi differenti, inclusa pubblicazione. Acquisire lo stato danneggiato prima di qualsiasi riparazione; recuperare copie quando possibile. Per ogni caso ripetere controlli Windows strutturali e hash dei file precedenti. Al primo errore fermare la campagna e riaprire il gate del protocollo.

### G5: rilascio

Richiedere runtime su M1/macOS 15.4 e Apple Silicon più recente, esito G4, interfaccia con stati corretti, nessuna fuga di nomi/contenuti nei log operativi e documentazione delle configurazioni supportate.

Soltanto G5 permette «Copia sul disco». Configurazioni non validate rimangono in sola lettura. Non dedurre compatibilità runtime dal deployment target. Le operazioni privilegiate devono conservare identità del chiamante, validazione del target ed esclusività senza richiedere il percorso FSKit a pagamento per il prodotto locale.

## 14. Artefatti e riproducibilità

Ogni campagna crea `Build/evidence/journal/<run-id>/` con permessi privati. Nomi qui indicati sono il contratto degli artefatti futuri:

- `manifest.json`: versione schema, baseline, commit/patch, hash binari, compilatore, opzioni, host, Windows build e geometria.
- `case.json`: caso, requisiti coperti, seed/algoritmo, guasto, confine di commit atteso, stato finale ammesso e risultato.
- `io-trace.jsonl`: sequenza, classe operazione, offset relativo al volume, lunghezza, transazione/LSN quando applicabile, accettazione/persistenza/sync e errore. Nessun contenuto dei file.
- `crash.*`: immagine intatta prima di Windows; `recovered.*`: copia dopo recupero e smontaggio.
- `windows/`: transcript completo, codici di uscita, impostazioni e registri, inventario e hash dei soli file sintetici.
- `structure-before.json`, `structure-after.json`: allocazioni e relazioni strutturali; anomalie con coordinate riproducibili.
- `SHA256SUMS` e `report.md`: integrità degli artefatti e decisione di gate con casi mancanti.

Le immagini e il manifest di test contengono dati sintetici; i log operativi del prodotto non devono contenere nomi o contenuti utente. Il wrapper che raccoglie gli artefatti deve essere esterno al processo sottoposto a crash. Non usare un `trap` che elimini la sola immagine fallita. Se manca spazio, fermarsi prima del caso successivo; niente cancellazione automatica delle evidenze.

In Git conservare specifiche, runner e rapporti sintetici privi di dati sensibili. Le immagini grandi restano fuori da Git, ma con hash e posizione nel rapporto. Non è un backup sufficiente avere originali e copie soltanto sullo stesso disco: per le prove fisiche conservare una seconda copia verificata del reperto importante.

## 15. Sequenza di lavoro e criteri di chiusura

| Ordine | Attività | Consegna verificabile | Dipendenza |
|---|---|---|---|
| T01 | Congelare inventario ed evidenze | Hash, stato sorgenti e controllo negativo riproducibile | Nessuna |
| T02 | Preparare Windows/VHD e controllo sano | Round-trip e rapporto sulla distinzione replay/riparazione | T01 |
| T03 | Rafforzare isolamento e simulatore | Test dei descrittori, cache prima del mount, artefatti conservati | T01 |
| T04 | Completare formato e matrice del sottoinsieme | `protocollo-logfile-ntfs.md`, parser e fixture decodificate | T02; ricerca in lettura può iniziare prima |
| T05 | Deliberare G0/G1 | Tutte le condizioni complete, nessuna lacuna necessaria | T02–T04 |
| T06 | Implementare primitive e creazione non residente | Writer sulle sole immagini, traccia completa delle mutazioni | G0/G1 |
| T07 | Costruire ed eseguire casi F0–F6 | Recupero Windows e rapporto G2 | T06 |
| T08 | Integrare copia limitata, rinomina e API strutturata | Contratti della sezione 11 e relativi test | G2 |
| T09 | Estendere log, campagne e recupero interrotto | Rapporto G3 e almeno 1.000 sequenze | T08 |
| T10 | Provare hardware e runtime | Rapporti G4/G5 | G3 |

Per chiudere un'attività registrare cosa è implementato, comandi effettivamente eseguiti, esiti, versione e limiti. Una suite verde del vecchio writer non chiude T06/T07. Nessun codice futuro deve essere descritto come già presente.

Durante T01–T07 mantenere le regressioni esistenti (`Tests/run-bridge-test.sh`, `Tests/run-offline-write-probe.sh`, `Tests/run-direct-copy-probe.sh`) quando si modificano i componenti coinvolti. Questi script sono controlli della base; non sostituiscono la nuova suite journal né il collaudo Windows. La sola stesura del presente documento non richiede eseguire test di scrittura.

## 16. Questioni aperte che bloccano l'avanzamento pertinente

| ID | Incognita | Come si chiude | Gate bloccato |
|---|---|---|---|
| Q01 | Versione LFS realmente prodotta e regole native necessarie | Fixture Windows, fonti e specifica binaria riscontrata | G1 |
| Q02 | Acquisizione affidabile di esempi attivi del journal | Metodo documentato e catture coerenti | G1 per i campi che ne dipendono |
| Q03 | Self-healing distinguibile dal replay dal primo accesso | Configurazione/strumentazione validata e controlli | G2 |
| Q04 | Mutazioni implicite di sicurezza, MFT e indice | Matrice completa, trace e controllo indipendente | G1/G2 |
| Q05 | Recupero Windows interrompibile in modo controllato | Banco dedicato con punti di interruzione registrati | G3 |
| Q06 | Durabilità effettiva attraverso API macOS/controller | Contratto del backend, test fisici e limiti espliciti | G4/G5 |

Se una questione resta irrisolta, consegnare un rapporto circoscritto: parte mancante, fonti esaminate, prove, alternative e impatto. Non dichiarare «NTFS sicuro impossibile» sulla base dell'assenza di una funzione nella libreria corrente; non dichiararlo possibile in produzione sulla base di una sola transazione riuscita.

## 17. Fonti e limiti delle evidenze

- [Rapporto forense OpenHDD](analisi-guasto-bitmap-ntfs-2026-09-27.md): prova reale, reperti, simulatori e inventario delle mutazioni.
- [Provenienza NTFS-3G](../vendor/README.md): archivio, checksum, versione e licenza del codice incluso. Ogni nuovo componente esterno richiede provenienza e licenza registrate; l'uso personale non rende automaticamente redistribuibile qualsiasi sorgente.
- [NTFS3, documentazione del kernel](https://docs.kernel.org/filesystems/ntfs3.html): distingue replay nativo e lavoro futuro sul journaling completo. Non è prova di un writer LFS utilizzabile nel progetto.
- [Linux-NTFS, formato `$LogFile`](https://flatcap.github.io/linux-ntfs/ntfs/files/logfile.html): materiale di ricerca per G1, con lacune e limiti di versione da verificare.
- [Microsoft, Mount-DiskImage](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage): supporto al laboratorio VHD senza VM.
- [Microsoft, fsutil repair](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-repair): self-healing distinto dal recupero transazionale; non prova la persistenza delle impostazioni attraverso ogni procedura di mount.

Fonti web consultate il 27 settembre 2026. Per una campagna conservare versione o copia delle fonti determinanti. La specifica va aggiornata quando cambia il protocollo supportato, senza retrodatare gli esiti delle prove.

**Definizione di successo del prossimo ciclo:** G0/G1 documentati e, se superati, un prototipo limitato che supera G2 su immagini recuperate da Windows. Fino a quel momento il risultato è ricerca verificabile; la scrittura sui dispositivi resta bloccata.
