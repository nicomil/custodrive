# OpenHDD — piano di scrittura NTFS v1 (percorso rapido)

Data: 27 settembre 2026. Sostituisce, per il primo rilascio con scrittura, il
percorso G1–G5 della [specifica transazionale](specifica-recupero-transazionale-ntfs.md).
Quella specifica resta valida come **fase 2** (journal `$LogFile` nativo), ma non
blocca più la v1.

## Perché cambiare piano

La specifica transazionale chiede che OpenHDD scriva transazioni `$LogFile` che
il driver Windows sappia riprodurre. È un lavoro di reverse engineering su un
formato non documentato da Microsoft: opcode, payload e catene undo/redo sono
ancora `NON_DEFINITI` e il gate G1 non ha una data prevedibile.

Il guasto reale osservato il 27 settembre (scollegamento durante una copia da
2 GiB) ha lasciato **cluster segnati occupati senza proprietario** in `$Bitmap`.
I cinque file preesistenti erano intatti. È il tipo di incoerenza che
`chkdsk /f` corregge liberando i cluster orfani, senza toccare i file esistenti.
Il problema vero non era la perdita di dati: era che **niente segnalava a Windows
che il volume andava controllato**, perché NTFS-3G non imposta mai il dirty bit.

## Definizione di sicurezza v1

La v1 promette queste proprietà, e solo queste:

| ID | Proprietà | Come si ottiene |
|---|---|---|
| S1 | I file già presenti non vengono mai modificati | Solo creazione di file nuovi. Niente sovrascrittura, cancellazione o rinomina di file esistenti. Nome già presente → rifiuto prima di scrivere |
| S2 | Nessun falso successo | Successo solo dopo sync del dispositivo, rilettura indipendente con SHA-256, rimozione del temporaneo, azzeramento del dirty bit e nuovo sync |
| S3 | Un'interruzione è sempre rilevabile e riparabile da Windows | Il dirty bit di `$Volume` viene scritto e sincronizzato **prima** di qualunque altra modifica e azzerato solo alla fine. Dopo un'interruzione Windows vede un volume da controllare; `chkdsk /f` lo riporta coerente. Nel caso peggiore si perde solo il file in copia |
| S4 | Nessuna scrittura su volumi a rischio | Rifiuto di volumi dirty, ibernati/Fast Startup, journal non pulito, `$TXF_DATA` non residente, temporanei OpenHDD residui, marcatore locale di trasferimento non concluso, spazio insufficiente |
| S5 | Nessuna riparazione automatica da Mac | Mai `ntfsfix`, reset del journal o rimozione di hiberfil. Un volume sospetto va su Windows |

Fuori dalla v1: sovrascrittura, cancellazione, rinomina, scrittura via Finder,
file compressi/sparsi/cifrati, garanzia contro guasti del controller USB.

## Sequenza di una sessione di copia

1. Identità del dispositivo, smontaggio normale, claim esclusivo (Disk Arbitration).
2. Marcatore locale su Mac (`/private/var/db/openhdd`) sincronizzato.
3. Preflight in sola lettura: S4, nomi liberi, spazio per tutti i file più riserva.
4. **Dirty bit acceso** → sync del dispositivo → rilettura che conferma il bit.
5. Per ogni file: temporaneo `.OpenHDD-pending-…` in radice, copia, sync,
   verifica SHA-256; hard link al nome finale nella cartella scelta, sync,
   verifica; rimozione del temporaneo, sync, verifica.
6. **Dirty bit spento** → sync → rilettura: volume pulito, nessun temporaneo.
7. Chiusura del dispositivo, rimozione del marcatore locale, rimontaggio in sola lettura.

Un'interruzione in 4–6 lascia il volume dirty (e di solito un temporaneo): la
v1 rifiuta nuove scritture su quel volume e indica di collegarlo a Windows.

## Gate v1

| Gate | Prova | Dove |
|---|---|---|
| V1 | Suite immagini: dirty bit acceso/spento, crash a ogni confine, errori I/O, disco pieno, nomi Unicode, cartelle, più file | Mac, `Tests/run-direct-copy-probe.sh` |
| V2 | Immagini dopo copia riuscita e dopo interruzione simulata (cache persa, bitmap orfana) convertite in VHD: Windows le monta; `chkdsk` in sola lettura; `chkdsk /f` sulle interrotte; secondo `chkdsk` pulito; hash dei file preesistenti invariati | minipc Windows, `Tests/windows/` |
| V3 | App: copia su un'immagine collegata come disco reale (`hdiutil attach`), rimontaggio in sola lettura, file leggibili dal driver macOS | Mac |
| V4 | USB sacrificabile: copie normali e scollegamento durante la copia, poi Windows | utente, checklist in README |

Il rilascio v1 richiede V1–V3 superati. V4 resta la conferma sull'hardware
dell'utente: un esito negativo riapre il piano.

## Esiti — 28 settembre 2026

| Gate | Esito | Evidenza |
|---|---|---|
| V1 | PASS | `Tests/run-direct-copy-probe.sh`; `Tests/run-powercut-campaign.sh` con strappi a 512 B (5 intatti, 32 marcati, 303 illeggibili da NTFS-3G) e a 4 KiB (5, 321, 14) su 340 tagli ciascuno: nessun volume pulito e alterato |
| V2 | PASS 22/22 | Base NTFS formattata da Windows 11 26200 (VHD fisso 64 MB, tre file preesistenti). Copia completata: `chkdsk` 0. Interruzioni agli stadi 3/5/6 e 18 tagli di corrente: Windows vede il volume dirty, l'evento NTFS 98 chiede `CHKDSK /F`; `chkdsk /f` → secondo `chkdsk` 0; file preesistenti intatti al loro percorso in tutti i casi. Due casi "illeggibili" avevano errori reali (`chkdsk` 3), corretti (`/f` 1) |
| V3 | PASS | Disco collegato con `hdiutil`: CLI e codice dell'app (`NTFSCopy.swift`) copiano in radice e in `Documenti`, rimontano in sola lettura; driver macOS legge hash corretti; Windows `chkdsk` 0. Poi copia guidata dall'interfaccia (clic reali): 2 file, messaggio «Copia completata e verificata», hash corretti, `chkdsk` 0. Il collaudo in interfaccia ha trovato un difetto: la copia intermedia di Xcode non conteneva il motore; ora lo incorpora una fase di build |
| V4 | PASS | Chiavetta reale: copie, scollegamento fisico, riparazione su Windows, ripresa (sezione sotto) |

Osservazioni:

- Windows **non** ripara da solo un volume dirty al collegamento: lo segnala
  (evento 98) e serve `chkdsk /f`. L'app lo dice esplicitamente.
- Il temporaneo `.OpenHDD-pending-…` sopravvive a `chkdsk /f`. Per questo la
  sessione successiva, su un volume ormai pulito, rimuove da sola i temporanei
  di OpenHDD, dentro una nuova sessione marcata.
- Con strappi a 512 byte i record MFT da 1 KiB possono restare a metà: NTFS-3G
  non monta più il volume, Windows sì, e `chkdsk /f` lo corregge. Sui supporti
  con settore fisico di 4 KiB (flash USB, dischi 512e/4Kn) il caso è raro.
- Il dirty bit protegge solo se il dispositivo rispetta il flush
  (`DKIOCSYNCHRONIZECACHE`). Un controller che mente sul flush resta un
  rischio residuo, da misurare con V4.

## V4 in corso — lezioni dalla chiavetta reale (28 settembre 2026)

Prima copia reale su `USB DISK 2.0` riformattata da Windows (`OPENHDD-V4`):
1,5 GiB più un file con nome accentato, hash corretti sul Mac, file
preesistenti intatti. Quattro problemi trovati solo sull'hardware reale:

| Problema | Causa | Correzione |
|---|---|---|
| «source is not a regular file readable» | Il motore lanciato come amministratore via AppleScript non può leggere la Scrivania (protezione privacy di macOS, iCloud Desktop) | Il motore gira come utente, figlio dell'app, con i suoi permessi sui file scelti |
| «exclusive open: Operation not permitted» | macOS nega l'apertura in scrittura del disco al processo amministratore lanciato da AppleScript, anche con Accesso completo al disco | Accesso al disco tramite `/usr/libexec/authopen` con un'unica autorizzazione (`-extauth`) per i due device |
| 4 MB/s, verifica tre volte più lunga della scrittura | Device a blocchi bufferizzato: macOS spezza l'I/O in comandi da 16 KB; tre riletture complete | I/O sul device raw a blocchi da 4 MB con strato di allineamento per i metadati; fasi a lotto con una sola rilettura dal disco |
| Barra ferma al 100% e stato «Trasferimento in corso» dopo la fine | La barra misurava solo la scrittura; la riga della lista non si ridisegnava | Barra unica pesata su scrittura e verifica, fase, velocità e tempo rimanente; stato incluso nell'identità della riga |

Dopo le correzioni, V4 completato sulla stessa chiavetta:

| Passo | Esito |
|---|---|
| Copia da 1,5 GB con il nuovo motore | 8 min contro 20 (scrittura limitata dalla chiavetta a ~4,4 MB/s con trasferimenti da 2 MB; verifica una sola volta a ~17 MB/s) |
| Scollegamento fisico durante la scrittura | L'app rileva «Device not configured», nessun falso successo; su Windows volume dirty, `chkdsk` senza incoerenze, `chkdsk /f` pulito, file preesistenti e copie precedenti intatti, nome finale non pubblicato |
| Ripresa dal Mac | Temporaneo rimosso, marcatore locale sbloccato, copia completata con hash corretto |
| Controllo finale su Windows | `chkdsk` «Nessun problema rilevato», 7 file con hash attesi |

Altri due casi trovati durante V4: il controllo «sorgente cambiata» scattava
per un attributo aggiunto da macOS al file scelto (ora conta solo il
contenuto); un disco staccato da Windows senza rimozione sicura ha il journal
aperto e viene rifiutato (comportamento corretto; ora il messaggio lo dice).

Sul device raw `O_EXCL` non impedisce il montaggio (prova su immagine): per
questo il device a blocchi resta aperto in esclusiva per tutta la copia.
Dopo le modifiche: suite su immagini verde, campagna di tagli con 21 scritture
per copia (erano 85) e zero violazioni, anche con settori da 4 KiB emulati.

## v2 — modifiche: nuova cartella, rinomina, elimina

Stesso protocollo della copia: dirty bit acceso e sincronizzato prima di ogni
modifica, tutte le modifiche di una richiesta in un solo montaggio, verifica in
sola lettura (nome sparito, nuovo nome sullo stesso inode, cartella creata),
dirty bit spento solo alla fine.

| Operazione | Implementazione | Stato intermedio dopo un'interruzione |
|---|---|---|
| Nuova cartella | `ntfs_create` di una directory | Cartella presente o assente; volume dirty |
| Rinomina | nuovo nome, poi rimozione del vecchio; solo maiuscole/minuscole passa da un nome temporaneo | Un elemento con due nomi o con uno solo; volume dirty |
| Elimina | albero visitato dal basso, `ntfs_delete` per ogni voce, junction/link simbolici/cifrati rifiutati prima | Parte dell'albero già eliminata; volume dirty |

Rifiuti preventivi: file di sistema (`$…`, `System Volume Information`),
temporanei OpenHDD, nomi non validi per Windows, nomi già presenti (senza
distinzione di maiuscole), elementi mancanti. Collaudo: `Tests/run-edit-probe.sh`
(operazioni, rifiuti a immagine invariata, crash, riparazione, errori I/O),
`OPENHDD_CAMPAIGN_EDIT=delete|rename|mkdir Tests/run-powercut-campaign.sh`
(0 violazioni con strappi a 512 B e 4 KiB), verifica Windows con
`Tests/prepare-windows-v2-edit-cases.sh`.

Esito Windows (28 settembre 2026): **46/46 PASS**. Le modifiche completate
(eliminazione, rinomina, anche solo maiuscole, cartelle annidate con nomi
accentati) passano `chkdsk` senza errori. Le interruzioni (stop ai confini
delle fasi e 38 tagli di corrente a 512 B e 4 KiB) lasciano volumi che
`chkdsk /f` ripara, con un secondo `chkdsk` pulito e tutti i file preesistenti
integri al loro posto.

Collaudo su disco reale (chiavetta OPENHDD-V4, stesso giorno): nuova cartella,
rinomina ed eliminazione eseguite dal menu Modifica dell'app; poi su Windows
volume sano, `chkdsk` in sola lettura senza errori e file preesistenti con
hash invariato. Per restituire il disco al Mac si usa
`Tests/windows/eject-usb.ps1 -Label ETICHETTA` (rimozione sicura vera).

## Fase 2

La specifica transazionale e il laboratorio `$LogFile` (`Tests/windows/*journal*`,
`acquire-logfile-replay_claude.ps1`) restano come ricerca per un recupero senza
`chkdsk`. Non bloccano la v1.
