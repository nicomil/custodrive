# OpenHDD — protocollo `$LogFile` NTFS

Stato: **G1 INCONCLUDENTE — writer disabilitato**  
Versione: 0.1  
Data: 27 settembre 2026

Questo documento è un artefatto SDD, non una specifica Microsoft completa e
non autorizza scritture. Riporta ciò che il codice locale consente di
verificare, separa osservazioni da ipotesi e lascia bloccata ogni regola che
richiede esempi Windows attivi. Il probe implementato in
`Tests/ntfs_journal_probe.c` apre solo immagini regolari con `O_RDONLY`, monta
NTFS con `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`, conta pagine `RCRD` e non
serializza transazioni.

## Fonti e classificazione

| Fonte | Classificazione | Uso ammesso |
|---|---|---|
| `vendor/ntfs-3g-2026.7.7/include/ntfs-3g/logfile.h` | documentato dal codice vendorizzato | offset e ampiezze delle strutture osservate |
| `vendor/ntfs-3g-2026.7.7/libntfs-3g/logfile.c` | comportamento del parser Linux-NTFS | validazione read-only, non prova Windows |
| `vendor/ntfs-3g-2026.7.7/ntfsprogs/ntfsrecover.c` | comportamento del tool di replay Linux-NTFS | riscontro secondario, non writer |
| immagini formattate da Windows + trace | da acquisire | unica evidenza per compatibilità del sottoinsieme |
| commenti `???`, `probably`, `presumably` nel vendor | ipotesi | mai base per un campo indispensabile |

Revisione vendor usata: `ntfs-3g-2026.7.7`, sorgente presente nel repository.
Non esiste ancora una fixture Windows acquisita dal runner macOS né un metodo
validato per catturare una transazione attiva.

## Strutture osservate

Endianess è little-endian per i campi `le16`, `le32`, `le64`, `leLSN`, `leVCN`
e `leLCN`. Le ampiezze e gli offset sotto derivano dalle struct packed del
header citato; la validità su una versione Windows specifica resta da provare.

### Restart page e restart area

| Campo | Offset | Ampiezza | Validazione locale | Stato G1 |
|---|---:|---:|---|---|
| `magic` | 0 | 4 | `RSTR`/`CHKD` tramite parser vendor | osservato nel codice |
| `usa_ofs`, `usa_count` | 4, 6 | 2, 2 | conteggio `1 + system_page_size / 512`, limiti nel page | osservato nel codice |
| `chkdsk_lsn` | 8 | 8 | zero salvo record `CHKD` | osservato nel codice |
| `system_page_size` | 16 | 4 | potenza di due, almeno 512 | osservato nel codice |
| `log_page_size` | 20 | 4 | potenza di due, almeno 512 | osservato nel codice |
| `restart_area_offset` | 24 | 2 | allineato a 8, dentro system page | osservato nel codice |
| `minor_ver`, `major_ver` | 26, 28 | 2, 2 | parser accetta 1.1 e 2.0 | compatibilità Windows da acquisire |
| `usn` | 30 | 2 | MS transfer protection | osservato nel codice |
| `current_lsn` | area + 0 | 8 | valore riportato dall'area selezionata | semantica completa non provata |
| `log_clients` | area + 8 | 2 | liste entro numero client | osservato nel codice |
| `flags` | area + 14 | 2 | `0x0002` è `RESTART_VOLUME_IS_CLEAN` nel vendor | correlazione Windows da provare |
| `file_size` | area + 24 | 8 | minimo per restart + 48 pagine; multiplo log page | osservato nel codice |
| `log_record_header_length` | area + 36 | 2 | multiplo di 8 | osservato nel codice |
| `log_page_data_offset` | area + 38 | 2 | multiplo di 8 | osservato nel codice |

Il parser vendor seleziona e deprotegge in memoria una copia di restart page;
il probe non riscrive la copia né il volume. La regola di selezione tra le due
copie, la priorità in caso di divergenza e la durabilità della scelta devono
essere riscontrate su campioni Windows.

### Record page e log record

`RECORD_PAGE_HEADER` occupa 64 byte nel header vendorizzato. Contiene `RCRD`,
USA, LSN/offset della pagina, flag, conteggio/posizione di pagina, offset del
prossimo record e `last_end_lsn`. Il probe conta pagine `RCRD` e presenza di
USA; non dichiara validi i record interni.

`LOG_RECORD` espone nel vendor:

- header da 0x30 byte: `this_lsn`, `client_previous_lsn`,
  `client_undo_next_lsn`, lunghezza dati, client id, tipo, transaction id e
  flag;
- a 0x30: redo/undo operation, offset e lunghezze;
- da 0x40: target attribute, numero LCN, offset record/attributo, cluster
  index, attribute flags e VCN.

Le costanti `LOG_STANDARD`, `LOG_CHECKPOINT`, `ACTS_ON_MFT` e `ACTS_ON_INDX`
sono disponibili nel vendor, ma non sono una lista sufficiente di opcode
Windows per creare una nuova transazione. Opcode, payload, catene undo/redo,
record di compensazione, transaction id e relazione con LSN MFT restano
**NON_DEFINITI** per il writer OpenHDD.

## Matrice mutazioni del primo caso

| Struttura | Mutazione prevista | Opcode/payload | Dipendenze | Prova |
|---|---|---|---|---|
| `$Bitmap` | allocazione cluster dati | **BLOCCATO** | MFT/data/index | campione Windows + recupero |
| `$MFT::$BITMAP` | allocazione record | **BLOCCATO** | record `FILE` valido | campione Windows + recupero |
| `$MFT` | `FILE_NAME`, `$DATA`, size, LSN | **BLOCCATO** | fixup, runlist, MFTMirr | campione Windows + struttura |
| indice root `$I30` | inserimento nome finale | **BLOCCATO** | FILE_NAME, eventuale split | campione Windows + indice |
| bitmap/record indice | allocazione o split | **BLOCCATO** | spazio indice pianificato | rifiuto preventivo finché non coperto |
| sicurezza e file sistema | eredità/riferimenti | **BLOCCATO** | security descriptor | matrice completa |
| `$Volume`/`$LogFile` | restart, commit, checkpoint | **BLOCCATO** | durabilità e riuso | recovery Windows |
| `$MFTMirr` | replica se richiesta | **BLOCCATO** | regole NTFS effettive | controllo offline |

Un buffer di vecchi byte, un log privato o una sequenza hard-link + delete non
soddisfano questa matrice. Fino a quando ogni riga non ha opcode, payload,
ordine, prova Windows e limiti, il writer deve rifiutare la richiesta prima di
ogni write.

## Cosa è implementato

- apertura con identity check dopo `lstat`, `O_NOFOLLOW`, `fstat`, inode/device/
  size invariati e rifiuto di symlink, device e hard link;
- mount forensic read-only e scansione bounded di `$LogFile`;
- trace numerico senza dati file;
- hash immutato prima/dopo;
- artefatti `manifest.json`, `case.json`, `io-trace.jsonl`, `SHA256SUMS` e
  `report.md` in `Build/evidence/journal/<run-id>/`;
- verifier Windows che rifiuta VHDX/raw, non esegue comandi di riparazione e
  resta `INCONCLUDENTE` se manca evidenza pre-mount del self-healing o la
  validazione strutturale offline.

## Gate

| Gate | Risultato | Motivo |
|---|---|---|
| G0 | NON_ESEGUITO | mancano baseline Windows, controllo sano e trasporto verificato |
| G1 | INCONCLUDENTE | manca specifica binaria verificata e cattura attiva coerente |
| G2 | NON_ESEGUITO | writer disabilitato; nessun recovery Windows attribuibile |
| G3 | NON_ESEGUITO | nessun banco per interrompere il recovery |
| G4/G5 | BLOCCATO | G2/G3 non passati; scrittura fisica e app escluse |

Un `PASS` del probe significa solo «ispezione read-only riuscita». Non significa
G1, recupero Windows, integrità strutturale o compatibilità hardware.

## Criteri per sbloccare il writer

1. Acquisire due immagini Windows indipendenti, con manifest di geometria e
   versioni.
2. Decodificare esempi equivalenti e completare ogni riga della matrice senza
   ipotesi indispensabili.
3. Aggiungere round-trip parser/serializer e prove di fault injection senza
   scrittura fisica.
4. Superare F0–F6 su Windows, con controllo offline indipendente e causalità
   positiva/negativa.

Fino ad allora non esiste API transazionale pubblica, nessun flag di bypass e
nessun esito `COMPLETED` per una scrittura NTFS.
