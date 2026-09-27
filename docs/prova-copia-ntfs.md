# Prova controllata della copia NTFS da Mac

**Solo unità USB sacrificabile, vuota o con backup verificato.** La prova modifica davvero NTFS. Non usarla su dati importanti. Il programma sperimentale è separato da OpenHDD Local: il pulsante di scrittura nell'app resta assente finché la prova fisica e il controllo Windows non passano.

## Preparazione

1. Su Windows, identifica la lettera dell'unità. Esegui `chkdsk X:` senza `/f` e salva l'esito. Espelli normalmente l'unità. Non usare una partizione ibernata o dirty.
2. Collega l'unità al Mac. In OpenHDD Local leggi l'identificativo della **partizione NTFS esterna**, per esempio `disk4s1`. Controlla anche la capacità. Non usare l'identificativo di un disco interno o quello del disco intero.
3. Il file di prova già preparato è `Build/openhdd-probe-8MiB.bin`; SHA-256: `69f4a57d6d6c0d87ebec0c9b1a275d3f7feb641d0083326137f617654ae52eef`.
4. Prima della copia, verifica quel valore con `shasum -a 256 /Users/nico/wa/open-hdd/Build/openhdd-probe-8MiB.bin`. Se differisce, interrompi.

## Copia

Sostituisci **solo** `disk4s1` con l'identificativo mostrato dall'app. Scegli un nome finale nuovo se ripeti la prova.

```sh
sudo /Users/nico/wa/open-hdd/Build/OpenHDDCopy --disk disk4s1 /Users/nico/wa/open-hdd/Build/openhdd-probe-8MiB.bin OpenHDD-test-20260925.bin
```

Il programma mostra identificativo, capacità, modello del dispositivo e nome del volume e richiede di digitare `COPY disk4s1`. Controlla tutti questi dati prima di confermare. Rilegge identità e formato, smonta normalmente tutti i volumi del dispositivo, reclama il disco in modo esclusivo e tenta apertura esclusiva della partizione. Se uno di questi controlli fallisce, non scrive. Verifica struttura, dirty bit, ibernazione, journal e rischio di riscrittura automatica del metadato `$TXF_DATA` in sola lettura. Non esegue recovery o riparazioni. Copia soltanto un file nuovo nella radice NTFS; il nome finale accetta solo lettere ASCII, cifre, punto, trattino e underscore. La sorgente deve appartenere all'utente che ha invocato `sudo`.

Durante la copia crea un file temporaneo con prefisso `.OpenHDD-pending-`. Dopo chiusura, flush e confronto SHA-256, pubblica il nome finale come hard link e lo verifica. La versione corrente rimuove il **solo nome temporaneo** dopo la verifica, sincronizza e verifica di nuovo il nome finale. Un temporaneo rimasto sul volume, anche con due hard link, blocca ogni nuova scrittura: può indicare un'interruzione dopo la pubblicazione. Non cancellarlo automaticamente né ripetere la copia. Un'uscita diversa da `PASS` non significa che il disco sia intatto: lascia l'unità collegata se l'espulsione è fallita e controllala su Windows.

Il programma tenta espulsione normale al termine. Riporta `PASS` solo dopo verifica dei byte, rimozione del nome temporaneo, seconda verifica, chiusura del dispositivo ed espulsione. Se il sistema non concede il blocco esclusivo o il flush della cache del dispositivo, rifiuta o segnala errore: non aggirare il controllo.

## Verifica dopo la prova

1. Ricollega l'unità al Mac in sola lettura. Calcola `shasum -a 256 /Volumes/NOME_VOLUME/OpenHDD-test-20260925.bin` e confronta con il valore della sorgente. Espelli normalmente.
2. Su Windows esegui di nuovo `chkdsk X:` **senza `/f`**; conserva il risultato. Controlla che il file finale sia leggibile e abbia dimensione 8 MiB. [Microsoft](https://learn.microsoft.com/windows-server/administration/windows-commands/chkdsk) indica che senza parametri il comando non corregge gli errori, ma può segnare il volume come pulito se non trova corruzione: non considerarlo una prova di zero scritture.
3. Se emergono errori, interrompi il collaudo. Non usare la scrittura OpenHDD su dischi importanti. Riporta il messaggio del programma e l'esito di `chkdsk`, senza condividere contenuti privati.

Questa prima prova non valida resistenza a scollegamento durante scrittura o perdita di alimentazione. L'app rimane in sola lettura fino al completamento della matrice di sicurezza in [percorso-senza-abbonamento.md](percorso-senza-abbonamento.md).

## Prima prova fisica — 25 settembre 2026

- Mac Apple M1, macOS 27.0; Kingston DataTraveler G3 da 16 GB, dichiarata sacrificabile dall'utente. L'unità OCLP-Installer è stata cancellata e riformattata in NTFS con NTFS-3G 2026.7.7. macOS ha riconosciuto la partizione `Windows_NTFS` e l'ha montata in sola lettura.
- Il comando `OpenHDDCopy` eseguito da Terminale ha riportato `PASS` secondo l'utente e ha espulso l'unità. Dopo reinserimento, la lettura indipendente tramite macOS ha trovato `OpenHDD-test-20260925.bin` da 8.388.608 byte: SHA-256 `69f4a57d6d6c0d87ebec0c9b1a275d3f7feb641d0083326137f617654ae52eef`, identico alla sorgente. Eject finale riuscito.
- Il nome `.OpenHDD-pending-...` è rimasto come secondo hard link allo stesso file, comportamento previsto dal prototipo. Non eliminarlo prima del controllo Windows.
- **Stato Windows:** Gestione disco vede la partizione NTFS da 16 GB ma non le ha assegnato automaticamente una lettera. Dopo assegnazione manuale, l'utente riferisce che il file è leggibile, che `chkdsk X:` senza `/f` non segnala errori e che `certutil -hashfile` restituisce lo stesso SHA-256 della sorgente. L'output completo di `chkdsk` e `certutil` non è stato acquisito. Nessuna riparazione automatica è stata eseguita.
- **Limite:** questa singola prova non copre perdita di alimentazione, scollegamento durante scrittura, disco pieno, errori hardware, file compressi/sparsi o altre unità NTFS. Il programma resta sperimentale e non va usato con dati importanti.

## Seconda prova fisica — file da 128 MiB

- Sulla stessa Kingston NTFS sacrificabile, `OpenHDDCopy` ha riportato `PASS` ed espulsione secondo l'utente. Il file nuovo `OpenHDD-test-128MiB.bin` misura 134.217.728 byte.
- Dopo reinserimento, macOS ha montato NTFS in sola lettura. SHA-256 del nuovo file: `66b2c41461ed686925b342a9bfadc0ceace20319cfd3575465c62da0cf2d566f`, identico alla sorgente. Anche il precedente file da 8 MiB conserva dimensione e SHA-256. Espulsione normale riuscita.
- **Stato Windows:** l'utente riferisce `chkdsk X:` senza errori e SHA-256 del nuovo file identico alla sorgente (`66b2c41461ed686925b342a9bfadc0ceace20319cfd3575465c62da0cf2d566f`). L'output completo non è stato acquisito. La prova non copre ancora guasti fisici o perdita di alimentazione.

## Arresto simulato su immagine, senza toccare la Kingston

- Su immagine NTFS privata, il processo è terminato subito dopo il primo blocco scritto, senza chiudere il file né smontare NTFS. Il nome finale non è apparso; il file `.OpenHDD-pending-...` è leggibile ma incompleto.
- `ntfsfix -n` ha superato i controlli limitati di MFT, mirror e boot sector senza modificare l'immagine. Non è un `chkdsk` completo. Questa prova non simula perdita di alimentazione: macOS può conservare e scaricare la cache dopo la fine del processo.
- La versione precedente accettava una nuova copia dopo l'arresto. La versione corrente rileva il file temporaneo con un solo hard link e **rifiuta nuove scritture**, lasciando invariato l'hash dell'immagine. Un temporaneo di una copia conclusa ha due hard link e non blocca le copie successive.
- Nessuna riparazione o cancellazione automatica. La scrittura su dischi con dati importanti resta esclusa finché guasti fisici, spegnimento improvviso e controlli Windows non sono verificati.

## Laboratorio fase 2 — errori su immagini

- `OpenHDDCopyTest` rifiuta ogni richiesta `--disk`. Errori iniettati su lettura, scrittura a blocchi, sincronizzazione e spazio esaurito durante la copia sono stati provati su immagini NTFS private.
- Nessun caso ha riportato `PASS`. Il file già presente è rimasto leggibile e identico alla sorgente. Il controllo `ntfsfix -n` non ha segnalato problemi di base; l'hash di ogni immagine è rimasto invariato durante il solo controllo.
- Se lo spazio libero dichiarato dalla bitmap NTFS è inferiore alla dimensione della sorgente più una riserva, la copia viene rifiutata prima di creare il file temporaneo. Nell'immagine piena di prova l'hash dell'intera immagine è rimasto identico.
- Un errore dopo la creazione del nome finale può lasciare quel nome visibile pur senza esito di successo. Non interpretare la presenza del file come prova che sia stato sincronizzato sul dispositivo. Mancano ancora guasti USB reali e `chkdsk` Windows sulle immagini dopo ogni scenario.

## Tentativo di prova con sorgente più grande dell'unità

- Il primo comando sulla Kingston è terminato con `stage 0; code 22`: il nome finale digitato aveva un punto in coda. Quindi **non ha esercitato il controllo dello spazio libero**. Il confronto successivo dell'intera partizione con la baseline è fallito; i log di lettura descritti sotto impediscono di usare quel confronto come prova di una scrittura.
- Il programma ora rifiuta nomi finali non validi prima di accedere al disco. Test su immagine: nome con punto finale respinto e SHA-256 dell'immagine invariato. La Kingston non è stata usata per la prova fisica di spazio insufficiente; vedi test successivo.
- Al reinserimento, prima di ripetere la prova, il controllo dell'intera partizione `/dev/rdisk4s1` **non ha coinciso** con la baseline `39dd85ef6204c334f8a5a5e2c4911a73aea7ac6f507621a009ddac664ae76a73`. Lo script si è fermato prima di avviare `OpenHDDCopy`; il volume è rimasto montato in sola lettura e il nome finale non esiste. Un'ulteriore lettura integrale eseguita dall'utente ha prodotto `f13c0e37d568b65324fed7a41e40345345d2d72402ef9939cc7f8c387b2107f6`. I file da 8 e 128 MiB mantengono gli hash attesi.
- I log kernel del 25 settembre mostrano errori `disk4s1: I/O error` alle 17:07, 17:42 e 17:58; nello stesso intervallo compaiono numerosi errori di lettura SCSI della DataTraveler G3, anche ripetuti sulle stesse aree. La baseline è stata calcolata intorno alle 17:07: **non è affidabile come prova che il programma abbia scritto o non scritto**. L'origine fisica degli errori non è stata isolata. La Kingston è stata espulsa normalmente e ritirata dalle prove di scrittura; la prova fisica di spazio insufficiente è stata poi eseguita su un'altra unità, descritta sotto.

## Prova fisica del rifiuto per spazio insufficiente — 26 settembre 2026

- Dispositivo: USB DISK 2.0, USB rimovibile da 3,9 GB, MBR, partizione `disk4s1`, NTFS `OPENHDDLAB`, macOS 27. La formattazione ha creato il volume NTFS; un helper ha verificato firma boot e geometria, aggiornando poi il tipo MBR a NTFS. Dopo reinserimento, macOS ha montato NTFS in sola lettura.
- Sorgente virtuale da 4 GiB supera lo spazio libero del volume. Il programma ha restituito `Copy failed at stage 1; code 28`, senza `PASS`, prima di creare un file temporaneo. L'espulsione è riuscita.
- Hash SHA-256 dell'intera partizione prima del tentativo: `5236eb5faf7c09f6094653cb9d4d68996e99dcdc751b9c68b0449e9fc660e816`. Dopo reinserimento, `shasum -a 256 -c` ha restituito `/dev/rdisk4s1: OK`. Il nome finale non esiste, non ci sono file temporanei OpenHDD e i log kernel non riportano errori I/O per questa unità durante la prova.
- Questo verifica il rifiuto preventivo su questo dispositivo e volume. Non verifica spazio esaurito a metà scrittura, copie riuscite, perdita di alimentazione, né la sicurezza su unità con dati importanti.

## Copie riuscite su USB DISK 2.0 — 27 settembre 2026

- Sulla USB sacrificabile `USB DISK 2.0`, 3,9 GB, volume NTFS `OPENHDDLAB`, `OpenHDDCopy` ha riportato `PASS` ed espulsione per file da 8 MiB e 128 MiB. L'identità della partizione era `disk4s1` al momento delle rispettive copie.
- Dopo ogni reinserimento, macOS ha riconosciuto la stessa partizione NTFS e l'ha montata in sola lettura. Il file da 8 MiB ha SHA-256 `69f4a57d6d6c0d87ebec0c9b1a275d3f7feb641d0083326137f617654ae52eef`; quello da 128 MiB, `66b2c41461ed686925b342a9bfadc0ceace20319cfd3575465c62da0cf2d566f`. Entrambi corrispondono alle sorgenti. Dimensioni e due hard link per file sono stati verificati; il nome `.OpenHDD-pending-...` resta intenzionalmente come secondo hard link.
- **Stato Windows riferito dall'utente:** per entrambi i passaggi, `chkdsk X:` senza `/f` non ha segnalato problemi e l'hash dei file su Windows coincide con quello della sorgente. Output completi non acquisiti.
- **Limite:** due copie verificate, su una sola unità, non provano sicurezza generale, tenuta a perdita di alimentazione o compatibilità con ogni volume NTFS. Non usare ancora il prototipo con dati importanti.

## Prova file vuoto fermata al preflight — 27 settembre 2026

- Tentativo di aggiungere `OpenHDD-test-empty.bin` (sorgente vuota) a `OPENHDDLAB`: il programma ha restituito `Copy failed at stage 1; code 16` (`EBUSY`), senza `PASS`, ed espulso l'unità.
- Dopo reinserimento, macOS vede ancora `OPENHDDLAB` come NTFS e monta il volume in sola lettura. I due file precedenti sono presenti con dimensioni e SHA-256 attesi. Il file vuoto e un nuovo temporaneo OpenHDD non compaiono. Il percorso `stage 1` termina prima della creazione del temporaneo nel codice attuale; non è stato confrontato l'hash completo della partizione dopo questo tentativo.
- La suite `Tests/run-direct-copy-probe.sh` passa su immagini NTFS private, incluso il caso file vuoto. Il binario usato per il tentativo fisico riduceva gli avvisi strutturali a `EBUSY`; la build aggiornata stampa le cause specifiche (`dirty`, ibernazione incerta, journal sospetto, rischio `$TXF_DATA`) e non scrive durante il preflight. Test immagine conferma diagnosi esplicita per volume dirty.
- È stata aggiunta la modalità `sudo Build/OpenHDDCopy --check-disk disk4s1`: richiede NTFS montato read-only, tenta smontaggio normale (mai forzato), apre il device in sola lettura, riusa il preflight delle copie e poi ripristina il mount read-only. Mostra avvisi, file temporanei incompleti e spazio libero; non ripara e non scrive.
- **Azione:** CHKDSK su Windows è stato riferito senza problemi. La modalità diagnostica read-only va eseguita prima di qualsiasi altro tentativo di scrittura. Non usare opzioni di riparazione.
- Dopo CHKDSK, la diagnostica read-only ha superato il preflight, riportando 3.708.321.792 byte liberi e ripristinando il mount read-only. La causa del precedente `EBUSY` non è stata stabilita.
- Secondo tentativo con la build aggiornata: `OpenHDDCopy` ha riportato `PASS` ed espulsione per `OpenHDD-test-empty.bin`. Dopo reinserimento, macOS legge il file da 0 byte con SHA-256 standard del file vuoto; file finale e nome pending condividono inode e due hard link. Nessun errore I/O nei log kernel controllati.
- Nella foto inviata, `dir D:\OpenHDD-test-empty.bin` mostra file da 0 byte su `OPENHDDLAB`, ma `certutil -hashfile ... SHA256` fallisce con `0x800703ee` / Win32 1006 `ERROR_FILE_INVALID`. Microsoft descrive 1006 come volume modificato esternamente mentre il file era aperto ([codice di sistema 1000–1299](https://learn.microsoft.com/it-it/windows/win32/debug/system-error-codes--1000-1299-)).
- Dopo espulsione e reinserimento su Windows, l'utente riferisce lo stesso 1006 sul file vuoto; gli hash dei file da 8 e 128 MiB sono nuovamente corretti. PowerShell `Get-FileHash` sul file vuoto NTFS restituisce l'hash atteso `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Il controllo `certutil` su un file vuoto temporaneo **locale a Windows** fallisce anch'esso con 1006. Quindi 1006 non distingue un problema del volume NTFS in questo ambiente; la sua causa resta sconosciuta. Questi esiti Windows sono riferiti dall'utente, senza output completo acquisito.
- Revisione del codice: `verify_file` iterava zero volte per un file vuoto, quindi la verifica interna del vecchio binario non apriva lo stream dati. Il codice ora apre lo stream e verifica EOF anche per size zero; `Tests/run-direct-copy-probe.sh` passa su immagine privata con questa verifica. Il binario usato nella prova fisica precedeva questa correzione.
- **Stato:** sospese altre scritture fisiche in attesa della revisione dei percorsi di errore e dei test su immagini. La lettura Windows del file vuoto è confermata da PowerShell, non da `certutil`; la scrittura NTFS del prototipo resta non validata per dati importanti.

## Revisione del motore su immagini — 27 settembre 2026

- La nuova versione rifiuta **qualsiasi** `.OpenHDD-pending-...` residuo, anche se ha due hard link: un arresto dopo la pubblicazione non può più essere scambiato per una copia conclusa. In caso di successo elimina soltanto il nome temporaneo, sincronizza e verifica ancora hash e inode del nome finale. In caso di errore non elimina né ripara automaticamente il residuo.
- `Tests/run-direct-copy-probe.sh` copre file da 0 e 1 byte, confini da 65.535/65.536/65.537 byte, contenuto UTF-8, chiamate I/O parziali, errore dopo scrittura parziale e arresti ai confini delle fasi 2–5 e dopo il completamento. Nei casi prima del completamento, una nuova copia sulla stessa immagine è rifiutata; il file preesistente conserva i byte. La lettura separata usa `ntfscat`, basato comunque sulla stessa libreria NTFS-3G: non equivale a una verifica Windows.
- **Impatto sul laboratorio fisico:** `OPENHDDLAB` contiene temporanei lasciati dalle versioni precedenti. La nuova versione deve rifiutarlo; non rimuovere quei nomi per far passare il preflight. Per il collaudo della nuova versione serve un volume NTFS sacrificabile ripreparato dopo aver conservato le evidenze necessarie. Nessuna prova fisica della nuova versione è ancora stata eseguita.
- Il comando per dischi fisici crea su Mac un marcatore locale in `/private/var/db/openhdd`, identificato da numero di serie NTFS e dimensione della partizione. Lo sincronizza prima della prima scrittura e lo rimuove solo dopo chiusura ed espulsione normali. Un errore o arresto tardivo lo lascia sul Mac e blocca nuove scritture sullo stesso volume, anche se il temporaneo NTFS è sparito. Nessun nome o contenuto di file viene registrato. La diagnostica `--check-disk` controlla anche questo marcatore. Non esiste ancora un comando automatico per cancellarlo dopo un errore: la verifica esterna su Windows resta obbligatoria.
- Un arresto del processo non simula perdita di alimentazione: il sistema può svuotare la cache in seguito. Restano necessari prova fisica controllata, `chkdsk` Windows senza riparazione e verifica dei file preesistenti prima di valutare l'uso su dati importanti.

## Preflight fisico dopo la revisione — 27 settembre 2026

- `USB DISK 2.0` è stata ricollegata come `disk4s1`, NTFS `OPENHDDLAB`, 3.876.323.328 byte, mount macOS in sola lettura. I file precedenti da 8 MiB, 128 MiB e zero byte conservano gli SHA-256 attesi. La radice contiene ancora tre nomi `.OpenHDD-pending-...` lasciati dalla vecchia versione.
- Il nuovo `OpenHDDCopy --check-disk disk4s1`, eseguito dall'utente, ha riportato `NTFS safety preflight refused: journal state suspect; no writes started.` e `NTFS restored as read-only.` Questo avviso blocca la diagnostica prima dell'enumerazione dei nomi temporanei; i temporanei costituiscono un secondo blocco indipendente. Nessuna prova di scrittura della nuova versione è iniziata.
- Prima di ripreparare il volume, verificare su Windows con `chkdsk X:` senza `/f` e conservare l'esito. Se il journal resta sospetto, non forzare il motore NTFS né correggere automaticamente il volume.
- L'utente riferisce `chkdsk X:` senza problemi. Ha poi riformattato **solo** la partizione della USB sacrificabile da 3,9 GB in NTFS tramite Windows ed espulso normalmente. Dopo reinserimento, macOS vede `disk4s1`, `OPENHDDLAB`, 3.876.323.328 byte, montata in sola lettura e senza vecchi temporanei. La diagnostica `--check-disk` ha riportato `Read-only NTFS safety preflight passed; 3861614592 bytes free. No writes attempted.` e `NTFS restored as read-only.` Il risultato Windows è riferito dall'utente senza output completo acquisito.

## Prima copia della versione aggiornata — file vuoto

- Sulla sola USB sacrificabile `USB DISK 2.0`, `disk4s1`, il comando per `OpenHDD-v2-empty.bin` ha riportato `PASS: copied, independently verified and ejected.` secondo l'utente. Dopo reinserimento, macOS ha montato `OPENHDDLAB` in sola lettura; il file misura zero byte, ha SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` e la radice non contiene nomi `.OpenHDD-pending-...`. Espulsione normale riuscita.
- L'utente riferisce `chkdsk X:` senza problemi e hash PowerShell identico all'atteso dopo reinserimento su Windows. Output completo non acquisito. Questo singolo esito non valida il comportamento con file grandi, errori del dispositivo o perdita di alimentazione.

## Seconda copia della versione aggiornata — 1 byte

- La USB corretta è stata ricollegata al Mac; file vuoto e mount read-only erano ancora integri. Il comando per `OpenHDD-v2-one-byte.bin` ha riportato `PASS: copied, independently verified and ejected.` secondo l'utente.
- Dopo reinserimento, macOS vede ancora `OPENHDDLAB` NTFS in sola lettura. Il nuovo file misura 1 byte e ha SHA-256 `2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881`; il file vuoto conserva l'hash atteso. Nessun temporaneo OpenHDD nella radice. Espulsione normale riuscita. L'utente riferisce `chkdsk X:` regolare e hash PowerShell corrispondenti per entrambi i file su Windows; output completo non acquisito.

## Terza copia della versione aggiornata — contenuto Unicode

- Sulla stessa USB sacrificabile, il comando per `OpenHDD-v2-unicode.txt` ha riportato `PASS: copied, independently verified and ejected.` secondo l'utente. La sorgente contiene testo UTF-8 e misura 65 byte; il nome di destinazione resta ASCII come richiesto dal motore attuale.
- Dopo reinserimento, macOS ha letto il nuovo file in sola lettura: 65 byte, SHA-256 `85df5f6f0236a4bffdc1d1d06786a688fcbc6d696a28f56879c0160fb4eaf2cd`, identico alla sorgente. File da 0 e 1 byte conservano gli hash attesi; nessun temporaneo OpenHDD nella radice. Espulsione normale riuscita. L'utente riferisce `chkdsk X:` regolare e hash PowerShell del nuovo file identico su Windows; output completo non acquisito.

## Quarta copia della versione aggiornata — 8 MiB

- Il comando per `OpenHDD-v2-8MiB.bin` sulla stessa USB sacrificabile ha riportato `PASS: copied, independently verified and ejected.` secondo l'utente.
- Dopo reinserimento, macOS legge il file da 8.388.608 byte con SHA-256 `69f4a57d6d6c0d87ebec0c9b1a275d3f7feb641d0083326137f617654ae52eef`, identico alla sorgente. File da 0, 1 e 65 byte conservano dimensioni e hash attesi; nessun temporaneo OpenHDD. Espulsione normale riuscita. L'utente riferisce `chkdsk X:` senza problemi e hash PowerShell del file da 8 MiB identico all'atteso su Windows; output completo non acquisito.

## Quinta copia della versione aggiornata — 128 MiB

- Il comando per `OpenHDD-v2-128MiB.bin` sulla stessa USB sacrificabile ha riportato `PASS: copied, independently verified and ejected.` secondo l'utente.
- Dopo reinserimento, macOS legge il nuovo file da 134.217.728 byte con SHA-256 `66b2c41461ed686925b342a9bfadc0ceace20319cfd3575465c62da0cf2d566f`, identico alla sorgente. I quattro file precedenti conservano dimensioni e hash attesi; nessun temporaneo OpenHDD nella radice. Espulsione normale riuscita. L'utente riferisce `chkdsk X:` senza problemi e hash PowerShell del file da 128 MiB identico all'atteso su Windows; output completo non acquisito.
