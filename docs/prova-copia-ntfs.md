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

Durante la copia crea un file temporaneo con prefisso `.OpenHDD-pending-`. Dopo chiusura, flush e confronto SHA-256, pubblica il nome finale come hard link e lo verifica di nuovo. **Il file temporaneo resta sul volume anche dopo esito positivo**, senza occupare una seconda copia dei dati. Non cancellarlo durante il primo collaudo; serve per esaminare eventuali errori. Un'uscita diversa da `PASS` non significa che il disco sia intatto: lascia l'unità collegata se l'espulsione è fallita e controllala su Windows. Non ripetere la copia sullo stesso nome.

Il programma tenta espulsione normale al termine. Riporta `PASS` solo dopo verifica dei byte ed espulsione. Se il sistema non concede il blocco esclusivo o il flush della cache del dispositivo, rifiuta o segnala errore: non aggirare il controllo.

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
