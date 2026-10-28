# OpenHDD — piano di scrittura NTFS v1 (percorso rapido)

Data: 27 settembre 2026. Sostituisce, per il primo rilascio con scrittura, il
percorso G1–G5 della [specifica transazionale](specifica-recupero-transazionale-ntfs.md).
Quella specifica resta valida come **fase 2** (journal `$LogFile` nativo), ma non
blocca più la v1.

## Perimetro attuale — 29 settembre 2026

Il piano v1 e gli esiti del 28 settembre sotto sono **storici**. Le versioni
successive aggiungono sostituzione, spostamento ed eliminazione: S1 non si
applica a queste operazioni. Dirty bit e sincronizzazione non garantiscono
che ogni interruzione sia riparabile: metadati spezzati e controller che non
rispettano il flush possono causare perdite. I risultati su Windows/USB di
una versione precedente non certificano automaticamente quella attuale.

Il diario applicativo v2 contiene un checksum SHA-256 del corpo, riferimenti
MFT con numero di sequenza e, per le sostituzioni, hash del nuovo contenuto.
Il checksum rileva alterazioni, **non autentica** il diario. Il recupero
valida tutti i record e le identità prima di modificare il volume; alias,
record duplicati, riferimenti obsoleti e contenuti incoerenti bloccano il
recupero senza scritture. Il vecchio formato resta leggibile per stati
non ambigui; una sostituzione legacy con due file diversi viene conservata
e rifiutata. Serve verifica manuale, non cancellazione forzata del diario.

`Tests/run-recovery-probe.sh` verifica questi casi su immagini sacrificabili,
incluse rinomine di cartelle in radice e ulteriori interruzioni del recupero.
`ntfsfix` compare solo come preparazione dei test, non come prova di `chkdsk`.
Le campagne powercut distinguono invarianti locali da recuperabilità:
uscita **77 / INCONCLUSIVE** se restano casi da verificare su Windows.
Commit, differenze locali, hash e classificazioni sono conservati in
`Build/evidence/powercut/`. Il collaudo del 30 settembre aggiunge 14 campagne
(358 interruzioni) e 89 casi verificati da Windows/chkdsk. Recupero Mac,
limiti dei campioni e prove USB sono registrati separatamente in
[sviluppo.md](sviluppo.md#collaudo-assistenza-al-recupero--30-settembre-2026).

Quando il recupero viene rifiutato, la sessione resta consultabile: l’app
mostra motivo e percorsi attesi, consente il salvataggio dei file leggibili
e del rapporto, e rivalida soltanto in sola lettura. Lo sblocco richiede
controlli completi superati; il diario non viene eliminato per aggirarli.

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

## Definizione iniziale di sicurezza v1 (storica)

Obiettivi iniziali del piano; S3 viene limitato dal perimetro attuale sopra:

| ID | Proprietà | Come si ottiene |
|---|---|---|
| S1 | I file già presenti non vengono mai modificati | Solo creazione di file nuovi. Niente sovrascrittura, cancellazione o rinomina di file esistenti. Nome già presente → rifiuto prima di scrivere |
| S2 | Nessun falso successo | Successo solo dopo sync del dispositivo, rilettura indipendente con SHA-256, rimozione del temporaneo, azzeramento del dirty bit e nuovo sync |
| S3 | Segnalare un'interruzione a Windows | Il dirty bit di `$Volume` viene scritto e sincronizzato **prima** delle modifiche e azzerato alla fine. Presuppone un dispositivo che rispetta il flush; `chkdsk /f` tenta la riparazione, senza garanzia sui dati recuperati |
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

## v3 — cartelle intere, sostituzione, spostamento, drag & drop

**Cartelle.** La copia riceve un elenco (`--manifest`, campi separati da NUL)
di cartelle da creare e di file, ciascuno con la propria cartella di
destinazione. Nella fase 2, dopo il dirty bit, vengono create le cartelle
mancanti, genitori prima dei figli; quelle esistenti vengono unite. Poi
scrittura, verifica, pubblicazione e completamento come nella v1, con la
cartella risolta file per file. Le cartelle vengono risolte senza mai
attraversare junction o link. Nomi che differiscono solo per le maiuscole
nella stessa cartella vengono rifiutati prima di scrivere.

**Lotti.** La CLI divide le copie grandi in lotti da al massimo 1000 file o
8 GB. Ogni lotto è una sessione completa: dirty bit, verifica, volume pulito.
L'avanzamento viene rimappato su un totale unico, per una sola barra e un
solo tempo stimato. Il limite dei file aperti viene alzato all'avvio.

**Sostituzione.** Il file nuovo viene scritto e verificato sotto un nome
temporaneo. Poi:
1. il diario `.OpenHDD-journal` (cartella, nome temporaneo del vecchio, nome
   finale) viene scritto, sincronizzato e riletto;
2. il vecchio file viene rinominato `.OpenHDD-old-<hex>` nella sua cartella;
3. il nuovo prende il nome;
4. i nomi temporanei e il vecchio file vengono rimossi;
5. il diario viene eliminato in una sessione separata.

Dopo un'interruzione e `chkdsk`, la sessione successiva applica il diario:
- nome finale presente: il vecchio viene eliminato;
- nome finale assente: il vecchio riprende il nome.

| Punto d'interruzione | Sotto il nome, dopo `chkdsk` e ripresa |
|---|---|
| prima del diario | file vecchio |
| vecchio messo da parte, nuovo non collegato | file vecchio (ripristinato dal diario) |
| nuovo pubblicato | file nuovo (il vecchio viene eliminato) |

**Spostamento.** Aggiunta del nome nella cartella di destinazione, poi
rimozione del vecchio: NTFS tiene il genitore in ogni nome, quindi una
cartella si sposta con tutto il contenuto. Vengono rifiutati:
- lo spostamento di una cartella dentro se stessa;
- lo spostamento nella stessa cartella;
- un nome già presente nella destinazione;
- elementi che si contengono a vicenda nella stessa richiesta;
- elementi protetti o speciali.

**Collaudo su immagini.**
- `Tests/run-v3-probe.sh`: cartelle annidate, vuote e unite, rifiuti a
  immagine invariata, lotti con una sola barra, sostituzione con recupero
  dal diario a ogni punto d'interruzione, spostamenti. **PASS**.
- `OPENHDD_CAMPAIGN_EDIT=move|tree|replace Tests/run-powercut-campaign.sh`:
  tagli a ogni scrittura, 4 semi, strappi a 512 B e 4 KiB. **0 violazioni.**
  Per la sostituzione, ogni immagine riparabile con `ntfsfix` viene ripresa
  dalla sessione successiva: nei 101 casi recuperati il nome contiene
  sempre il file vecchio o quello nuovo, senza residui.

**Collaudo su Windows** (`Tests/prepare-windows-v3-cases.sh` +
`verify-v1-cases.ps1`, 28 settembre 2026): **47/47 PASS**.
- **Copie completate**: una cartella con unione in una cartella creata da
  Windows, la sostituzione di file creati da Windows e lo spostamento di una
  cartella e di un file di Windows danno `chkdsk` pulito.
- **Interruzioni e 38 tagli di corrente**: `chkdsk /f` ripara, e il secondo
  `chkdsk` è pulito.
- **Contenuti**: il contenuto vecchio o quello nuovo di ogni file sostituito
  sopravvive sempre, e i file di Windows non coinvolti restano intatti.

Un primo giro aveva segnato 7 falsi allarmi. Il test pretendeva il contenuto
vecchio anche dopo la pubblicazione, quando il motore lo elimina di proposito.
Corretta l'attesa ("vecchio o nuovo"), i 18 casi di sostituzione passano tutti.

**Giro completo Windows → Mac.** Due immagini riparate da Windows sono
tornate sul Mac, e la sessione successiva di OpenHDD ha applicato il diario:
- interruzione con il vecchio file messo da parte: `old.bin` torna il vecchio;
- interruzione dopo la pubblicazione: `old.bin` resta il nuovo.

In entrambi i casi non restano residui `.OpenHDD` e il volume è pulito.

**Disco reale** (chiavetta OPENHDD-V4, 28 settembre 2026). Dall'app:
- una cartella di 322 MB con sottocartelle, una cartella vuota e nomi
  accentati, copiata trascinandola dal Finder;
- la stessa cartella trascinata di nuovo, con **Sostituisci**;
- lo spostamento della cartella intera in `Documenti`.

Il Mac trova gli hash corretti. Windows trova il volume sano, `chkdsk` pulito,
12/12 hash identici e nessun residuo OpenHDD.

**Scoperta durante il collaudo.** Su macOS NTFS-3G restituisce i nomi degli
elenchi in forma decomposta (NFD). I confronti di nomi del motore ora
avvengono in forma canonica.

## v3.1 — annulla, avanzamento della preparazione, diario per sposta e rinomina, velocità

**Annulla.** L'app manda SIGINT allo strumento; la CLI lo intercetta per
l'intera sessione dopo la conferma. Il motore controlla la richiesta:
- **tra un lotto e l'altro**: si ferma, e i lotti completati restano;
- **durante scrittura o verifica** (niente è ancora pubblicato): annulla il
  lotto. Rimuove le cartelle create dal lotto (vuote, perché i file
  aspettano nella radice) e i temporanei, poi toglie il dirty bit e
  controlla che il volume sia pulito;
- **dalla pubblicazione in poi**: la richiesta viene ignorata e il lotto si
  completa.

Se l'annullamento stesso fallisce, il volume resta marcato come dopo
qualunque errore. Una richiesta arrivata prima che lo strumento sia partito
viene conservata e consegnata appena parte.

**Preparazione.** La visita delle cartelle aggiorna il conteggio dei file e
dei byte trovati, e si può annullare.

**Diario per sposta e rinomina.** Prima delle modifiche viene scritto
`.OpenHDD-journal` con righe tipizzate: `L` (da, a) per spostamenti e
rinomine, `C` (cartella, nome temporaneo, nome finale) per il solo cambio di
maiuscole; le sostituzioni usano `R`. Dopo `chkdsk`, la sessione successiva:
- `L`: toglie il nome vecchio se entrambi i nomi portano allo stesso
  elemento;
- `C`: toglie il nome temporaneo, oppure lo trasforma nel nome finale se non
  resta altro.

I temporanei già sistemati dal diario non vengono cancellati una seconda
volta.

**Diario delle cartelle create (versione 3, 28 ottobre 2026).** Una copia che
crea cartelle nuove scrive, subito dopo averle create, un diario con
intestazione `OpenHDD-Journal\t3` e una riga `D` (cartella madre, nome,
riferimento MFT) per ciascuna, madri prima. Il diario viene riletto come gli
altri e tolto prima della pubblicazione del primo file: da lì in poi le
cartelle fanno parte del risultato. Dopo un'interruzione e `chkdsk`, il
ripristino toglie, dalle più profonde, solo le cartelle che hanno ancora lo
stesso riferimento MFT e sono vuote (contando come vuote quelle che
contengono solo altre cartelle del diario già pianificate). Una cartella
sparita, rinominata, sostituita o non vuota resta com'è e non blocca il
ripristino: lasciarla non mette a rischio dati. Il diario v3 contiene solo
righe `D`; il v2 non le accetta. Oltre 4096 cartelle il diario non viene
scritto e le cartelle restano come prima della v3. Le build fino alla 1.1.0
rifiutano un diario v3 senza modificare nulla.

**Velocità con cartelle grandi.** I nomi di una cartella vengono letti una
sola volta: chiavi UTF-16 in maiuscolo con la tabella upcase del volume, la
stessa regola di NTFS, ordinate per una ricerca binaria. Prima si rileggeva
la cartella intera per ogni file. Misura su immagine: 3000 file piccoli in
una cartella in 0,6 s, poi altri 2000 nella stessa cartella in 0,4 s.

**Bug trovato e corretto (presente dalla v1).** `write_all` teneva aperta la
radice per tutto il lotto. Dopo circa 15 nomi temporanei l'indice della
radice esce dall'index root, e la chiusura del file successivo non trovava
più la propria voce ("Index lookup failed, inode 5", EIO). La copia si
fermava in sicurezza, con il volume marcato, ma non riusciva a copiare molti
file per lotto. Ora la radice viene aperta e chiusa attorno a ogni
creazione. Regressione: 300 file piccoli in un lotto solo.

**Collaudo v3.1.**
- `run-v3-probe.sh`: annullamento a metà lotto e tra un lotto e l'altro,
  recupero dal diario di spostamenti (file e cartella), rinomine e cambi di
  maiuscole interrotti con due nomi. **PASS**, insieme ai probe v1 e v2.
- Campagne di taglio corrente su tutte e 7 le operazioni (copia, cartelle,
  sostituzione, spostamento, rinomina, nuova cartella, eliminazione), a
  512 B e 4 KiB, 716 tagli in tutto: **0 violazioni**.
- Windows, 15 casi nuovi: **15/15 PASS**.
  - 300 file piccoli copiati: `chkdsk` pulito.
  - Copia annullata: volume pulito, niente di aggiunto.
  - Spostamento e rinomina interrotti con due nomi: riparati da
    `chkdsk /f`.
  - 11 tagli durante una rinomina: riparati da `chkdsk /f`.
- Giro Windows → Mac sui due casi con due nomi: dopo `chkdsk`, Windows mostra
  la cartella spostata in entrambe le posizioni e il file rinominato con
  entrambi i nomi. La sessione successiva di OpenHDD toglie il nome vecchio e
  il volume resta pulito, con contenuti intatti.
- Chiavetta reale: una copia annullata dall'app a metà scrittura dà
  «Copia annullata, il disco è pulito». Sul Mac non resta nessun residuo
  `.OpenHDD`, i file di controllo sono intatti e la copia precedente
  (390 MB) è integra.

## v4 — esperienza in stile Finder

**Sessione di modifica** (`OpenHDDCopy --disk diskXsY --session`). Lo
strumento esegue una sola volta autorizzazione, smontaggio, apertura
esclusiva e marker locale, poi serve i comandi da stdin fino a `end` o alla
fine dell'input (app chiusa o andata in crash). In quel caso rimonta il disco
in sola lettura.

Protocollo:
- ogni messaggio è formato da campi terminati da NUL, e il primo campo è il
  numero dei successivi;
- ogni risposta ha come ultimo campo la diagnostica catturata da stderr
  durante il comando.

Comandi:
- `list` e `export` passano da una vista in sola lettura sullo stesso
  descrittore esclusivo, chiusa prima di ogni scrittura;
- `copy`, `mkdir`, `rename`, `move` e `delete` eseguono esattamente le stesse
  transazioni delle invocazioni singole: dirty bit, verifica, diario, lotti,
  annullamento.

Un errore che lascia il volume marcato fa terminare la sessione con esito
negativo, e il marker locale resta. SIGINT a riposo viene ignorato; durante
una copia annulla il lotto in corso.

**App.**
- **Browser**: lista `NSTableView` con colonne ordinabili; dati dal mount in
  sola lettura di macOS, o dalla sessione quando il disco è in modifica.
- **Gesti**:
  - trascinamento dal Finder (copia) e tra cartelle (spostamento);
  - rinomina nella lista (Invio);
  - ⌘⌫, ⇧⌘N, ⌘X/⌘V, menu contestuale;
  - Quick Look (in sessione il file viene esportato in una cartella
    temporanea, fino a 2 GB).
- **Coda**: le richieste di copia vengono preparate una alla volta, poi tutte
  le scritture passano da un'unica coda.
- **Punto d'ingresso dal Finder**: voce Servizi e file trascinati sull'icona
  nel Dock, verso la cartella aperta; se ci sono più dischi NTFS senza
  selezione, l'app chiede.
- **Finestra unica**, e alla chiusura dell'app la sessione viene terminata
  con il rimontaggio del disco.

**Collaudo.**
- `Tests/run-session-probe.sh`:
  - 11 operazioni con una sola apertura;
  - elenco ed esportazione;
  - rifiuti per singolo comando, con la sessione che resta utilizzabile;
  - fine dell'input;
  - volume marcato dopo un errore iniettato;
  - annullamento in sessione e SIGINT a riposo.
  
  **PASS**, insieme ai probe v1, v2 e v3.
- Interfaccia guidata con l'automazione su un'immagine collegata:
  - sessione;
  - nuova cartella con rinomina immediata;
  - rinomina nella lista con un accento;
  - ⌘X/⌘V con apertura automatica della sessione;
  - copia dal Dock (file e cartella);
  - voce Servizi;
  - ⌘⌫ con conferma;
  - coda di tre copie;
  - sostituzione;
  - Termina modifiche, Espelli con sessione attiva, uscita dall'app con
    sessione attiva.
  
  Dopo tutto questo, volume pulito, nessun residuo, hash giusti, e Windows
  dà `chkdsk` pulito (**PASS**).
- Trascinamento e Quick Look non si possono generare con l'automazione, che
  non crea sessioni di drag AppKit. Li copre `Tests/run-ui-selftest.sh`: una
  build con `OPENHDD_UI_SELFTEST` (mai inclusa nell'app normale) guida dal
  proprio interno il data source reale della tabella, con un
  `NSDraggingInfo` sintetico:
  - validazione e drop di file del Finder su una cartella (copia);
  - trascinamento di una riga su una cartella (spostamento);
  - rifiuto di una cartella trascinata su se stessa;
  - apertura di Quick Look, verificata come visibile con il file esportato
    dalla sessione;
  - fine sessione e rimontaggio.
  
  Lo script poi controlla i contenuti e che il volume sia pulito. **PASS.**
- **Bug trovato dall'auto-test.** Per cartelle sotto percorsi con link
  simbolici (`/var`, `/tmp`) lo scanner calcolava il percorso relativo
  togliendo il prefisso come stringa. L'enumeratore restituisce
  `/private/var/...`, quindi le cartelle risultavano annidate due volte. Il
  motore rifiutava la copia senza toccare il disco. Ora il percorso relativo
  usa la profondità dell'enumeratore.

**Prestazioni dell'elenco.** La vista in sola lettura della sessione legge a
blocchi di 256 KiB e serve da memoria le letture piccole (record MFT, indici).
È coerente perché la vista viene chiusa prima di ogni scrittura. Per elencare
3000 voci le letture sul dispositivo scendono da 3197 a 899, e su immagine
l'elenco richiede circa 0,05 s.

## Fase 2

La specifica transazionale e il laboratorio `$LogFile` (`Tests/windows/*journal*`,
`acquire-logfile-replay_claude.ps1`) restano come ricerca per un recupero senza
`chkdsk`. Non bloccano la v1.
