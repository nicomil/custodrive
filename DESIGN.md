# Open HDD — proposta di sistema

**Stato:** progetto, non implementazione. **Priorità assoluta:** integrità dei dati.

## Decisione di prodotto

App gratuita per Mac Apple Silicon (M1 e successivi), con macOS 15.4 o successivo. Usa i driver di macOS per APFS, HFS+, exFAT e FAT. Per NTFS usa un modulo dedicato in spazio utente basato su FSKit. Nessuna estensione kernel e nessuna modifica alla sicurezza di avvio del Mac.

Il rilascio iniziale espone NTFS in sola lettura. La scrittura NTFS arriva solo dopo la validazione dei criteri sotto. Fino ad allora l'app può preparare modifiche sul disco interno, ma non le presenta come già salvate sul dispositivo NTFS.

## Limite fisico da dichiarare

Nessun software può promettere che un comune disco USB resti sempre coerente se cavo, alimentazione, controller o cache del dispositivo falliscono durante una scrittura. Anche il modello di transazioni NTFS di Microsoft dipende dall'ordine delle scritture e dalle garanzie del supporto. Il prodotto deve quindi promettere solo proprietà verificabili: rifiutare scritture rischiose, non dichiarare completata una scrittura prima della sincronizzazione, preservare una copia recuperabile dei dati sostituiti e rilevare/gestire un volume sospetto al reinserimento. Se la prova su hardware reale non soddisfa questi criteri, la scrittura resta disabilitata.

## Architettura

```text
Dispositivo USB/Thunderbolt
        │
        ▼
Rilevamento e classificazione ──► APFS/HFS+/exFAT/FAT: driver macOS
        │
        └──► NTFS: FSKit (volume e I/O in spazio utente)
                       │
                       ├── motore NTFS verificato e aggiornato
                       ├── controlli di stato e compatibilità
                       ├── scritture sequenziate + sync + verifica
                       └── UI SwiftUI: stato, trasferimenti, espulsione
```

FSKit fornisce accesso a partizioni e operazioni di lettura/scrittura; il motore NTFS resta un componente separato, con un adattatore per le API FSKit. Nella fase di scrittura controllata, il modulo FSKit in sola lettura viene smontato: un servizio locale con privilegi limitati ottiene accesso esclusivo alla partizione, applica il trasferimento e la verifica, poi rimonta il volume in sola lettura. Il servizio deve rifiutare richieste su dischi diversi da quello identificato e non espone accesso generico ai blocchi all'interfaccia. La scrittura via Finder richiede un modulo FSKit RW distinto e una validazione successiva.

`libntfs-3g` è una base candidata, **non ancora approvata**: vanno verificati porting, semantica di flush, recovery, sicurezza su volumi corrotti, licenza GPL e interoperabilità Windows. Non usare il backend macFUSE come dipendenza di sicurezza: aggiunge un livello e presenta limitazioni note. Un progetto FSKit/NTFS open source esiste, ma le sue affermazioni richiedono audit e prove indipendenti prima di riusarlo.

## Politica di montaggio

| Condizione | Comportamento |
| --- | --- |
| Volume NTFS pulito, formato supportato, controlli superati | Lettura; scrittura solo se la versione ha superato i gate di rilascio |
| Dirty bit, journal non pulito, ibernazione/Fast Startup, errore di struttura | Sola lettura; diagnosi chiara; riparazione con strumenti Windows dopo backup |
| BitLocker/EFS senza chiave, Storage Spaces, ReFS, configurazione sconosciuta | Nessuna scrittura; lettura solo se tecnicamente affidabile |
| Errori I/O, disconnessione, timeout, spazio insufficiente, identità volume cambiata | Stop immediato delle nuove scritture; stato «verifica necessaria» |

Mai usare opzioni che cancellano il file di ibernazione, azzerano il journal NTFS o forzano il montaggio in scrittura. Mai «riparare» automaticamente un volume NTFS: `ntfsfix` non equivale a `chkdsk`.

## Protocollo di scrittura proposto

1. Identificare il volume con più segnali: seriale NTFS, UUID partizione, dimensione, geometria e identificativo del dispositivo. Ottenere accesso esclusivo; nessun altro driver deve montarlo in scrittura.
2. Verificare stato NTFS, spazio libero, salute I/O e versione del motore. Se un controllo è incerto, restare in sola lettura.
3. Per sostituzioni/eliminazioni, salvare prima una copia recuperabile su APFS locale e verificarne hash e dimensione. Se manca spazio per la copia, rifiutare l'operazione.
4. Scrivere nuovi contenuti su file temporaneo NTFS. Sincronizzare dati e metadati, rileggere e confrontare hash/dimensione. Solo poi rendere visibile il nuovo nome con operazione di rename; sincronizzare di nuovo. L'atomicità effettiva del rename e del flush sul motore scelto va dimostrata, non presunta.
5. Registrare su APFS l'esito e i riferimenti di recupero, senza memorizzare contenuti sensibili nei log. Mostrare «completato» solo dopo le verifiche. Espulsione: bloccare nuove operazioni, terminare quelle in corso, sync, unmount, eject; se un passaggio fallisce, non mostrare «puoi scollegare».
6. Al reinserimento dopo crash/disconnessione, aprire in sola lettura, verificare identità/stato del volume e riconciliare il registro locale. Mai riprendere una scrittura automaticamente su un volume diverso o sospetto.

La copia locale protegge i file sostituiti; non sostituisce un backup completo e non garantisce da sola la coerenza delle strutture NTFS. Se serve tale garanzia anche dopo scollegamento arbitrario a metà scrittura, occorre dimostrare un protocollo di recovery interoperabile con Windows e con l'hardware reale. In assenza di tale prova, niente scrittura generale via Finder.

Il disco esterno è input non fidato: analisi NTFS isolata, privilegi minimi, limiti di memoria/tempo, aggiornamenti firmati e nessuna telemetria dei nomi o contenuti dei file. Le copie di recupero locali sono protette dai permessi dell'utente e cancellate solo con scelta esplicita o dopo il periodo di conservazione dichiarato.

## Esperienza utente

- Stato per ogni disco: **Solo lettura**, **Pronto a scrivere**, **Trasferimento in corso**, **Verifica necessaria**.
- Motivo concreto di ogni blocco; nessun pulsante «forza comunque».
- Copia, sostituzione ed eliminazione tracciate con progresso, bytes verificati e recupero dalla copia locale.
- Espulsione sicura prominente; avviso se applicazioni tengono file aperti.
- Nessuna formattazione o conversione implicita.

## Gate prima della scrittura NTFS

1. **Audit tecnico:** scegliere e fissare versione del motore; esaminare codice di gestione journal, dirty bit, flush, rename, allocazione cluster, file sparsi/compressi, ACL, Unicode e limiti di dimensione. Fuzzing su immagini NTFS malformate; nessun crash con privilegi elevati.
2. **Prove su immagini sacrificabili:** operazioni create/replace/delete/rename, file grandi, disco pieno, errori I/O simulati, arresto del processo in ogni punto di sincronizzazione; confronto byte per byte e `chkdsk` Windows dopo ogni scenario.
3. **Prove fisiche:** M1 e un Apple Silicon successivo; HDD e SSD, USB-C e hub, settori 512e/4Kn, sospensione/riattivazione, cavo rimosso e alimentazione interrotta durante scritture; ripetizioni automatiche. Controllare esito su macOS e Windows. Nessun dato reale usato nei test distruttivi.
4. **Criterio di uscita:** nessuna perdita dei file precedenti, nessun «successo» falso, nessuna modifica a volume rifiutato, nessuna corruzione strutturale non recuperabile nei casi di guasto dichiarati supportati. Ogni violazione blocca il rilascio RW. Il prodotto specifica esplicitamente i guasti hardware che non può coprire.

## Fasi

1. **Prototipo in sola lettura:** rilevamento, FSKit, diagnostica, interfaccia, espulsione. Nessun accesso in scrittura al dispositivo NTFS.
2. **Laboratorio di scrittura:** motore e test solo su immagini/dischi sacrificabili; audit e compatibilità Windows.
3. **Scrittura controllata:** trasferimenti gestiti dall'app, backup locale obbligatorio, sync e verifica; rilascio solo se i gate passano.
4. **Scrittura tramite Finder:** valutazione separata dopo prove di concorrenza, applicazioni terze, mmap, sleep e crash. Può restare esclusa se riduce la sicurezza.

## Fonti primarie consultate (24 settembre 2026)

- Apple: [FSKit](https://developer.apple.com/documentation/FSKit), [FSBlockDeviceResource](https://developer.apple.com/documentation/fskit/fsblockdeviceresource), [macOS 15.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes?language=objc), [limite NTFS di Utility Disco](https://support.apple.com/en-ie/101830).
- Tuxera: [NTFS-3G manual](https://github.com/tuxera/ntfs-3g/wiki/Manual), [codice e licenza](https://github.com/tuxera/ntfs-3g), [limiti di ntfsfix](https://github.com/tuxera/ntfs-3g/blob/edge/ntfsprogs/ntfsfix.8.in).
- macFUSE: [backend FSKit e limiti](https://github.com/macfuse/macfuse/wiki/FUSE-Backends).
- Microsoft: [limiti delle transazioni NTFS con dischi comuni](https://learn.microsoft.com/en-us/windows/win32/fileio/deploying-transactional-ntfs), [CHKDSK](https://learn.microsoft.com/windows-server/administration/windows-commands/chkdsk).
- Candidato da sottoporre ad audit: [NTFSKit](https://github.com/whereteam/ntfskit). Le prestazioni e garanzie descritte nel suo README sono dichiarazioni del progetto, non risultati qui verificati.
