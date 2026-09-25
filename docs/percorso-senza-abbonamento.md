# Percorso gratuito verso lettura e scrittura

## Decisione tecnica

Per i dischi che possono cambiare formato, usare i driver di macOS: APFS per uso Mac, exFAT quando serve collegarli direttamente anche a Windows. La migrazione richiede copia verificata dei dati prima di cancellare o formattare il disco. Non è una conversione sul posto.

Per i dischi che **devono restare NTFS**, mantenere la lettura macOS in sola lettura. Quando un computer Windows è disponibile, le scritture possono passare da una condivisione di rete ospitata da Windows, che gestisce direttamente NTFS.

Per scrivere su NTFS **dal solo Mac, senza abbonamento Apple**, OpenHDD dispone ora di un gestore di trasferimenti offline basato su NTFS-3G. Opera sulla partizione smontata, senza FSKit, senza macFUSE e senza montare NTFS in scrittura nel Finder. Questa prima versione sperimentale scrive soltanto nuovi file nella radice del volume; sovrascritture, cancellazioni e rename restano disabilitati.

`OpenHDDLocal.app` legge NTFS con il driver macOS e permette l'espulsione; resta sola lettura. `Build/OpenHDDCopy` è il programma separato per una **prova su unità sacrificabile**, descritta in [prova-copia-ntfs.md](prova-copia-ntfs.md). Il test `Tests/run-direct-copy-probe.sh` verifica il nuovo motore su immagini NTFS private: file grande e vuoto, hash, rifiuto di duplicati/dirty/non NTFS, tre errori iniettati e arresto del processo dopo il primo blocco. Una sua immagine GPT/NTFS è stata letta dal driver macOS in sola lettura. Due prove fisiche sulla Kingston USB da 16 GB hanno prodotto file da 8 e 128 MiB con hash identici alle sorgenti su Mac; l'utente riferisce hash identici e `chkdsk` senza errori anche su Windows, dopo assegnazione manuale della lettera. I guasti reali restano da verificare. Il motore non è validato per dati importanti. In caso di errore può restare un file temporaneo parziale e non si può escludere un problema strutturale.

L'arresto simulato lascia un file `.OpenHDD-pending-...` incompleto. `ntfsfix -n` non ha segnalato errori nella struttura di base, ma questo non equivale a `chkdsk` né prova la tenuta a perdita di alimentazione. Prima della correzione, il programma accettava un'altra copia sulla stessa immagine. Ora rifiuta nuove scritture se trova un file temporaneo OpenHDD senza il secondo hard link della pubblicazione; non elimina né ripara il residuo automaticamente. Un file temporaneo con due link, lasciato da una copia completata, rimane ammesso.

## Requisiti del gestore offline

1. CLI locale con richieste tipizzate, ora disponibile per il collaudo controllato. L'interfaccia grafica per preparare il trasferimento resta da realizzare dopo la prova fisica. I permessi amministrativi sono richiesti per la singola operazione tramite `sudo`; il percorso definitivo di autenticazione deve essere verificato su macOS 15.4 e 27 senza certificato a pagamento.
2. Verifica identità della partizione esterna immediatamente prima di aprirla; rifiuto se il dispositivo cambia, è occupato, già montato o non è NTFS. Niente smontaggio forzato e niente scrittura su dischi interni.
3. Preflight di sola lettura: rifiutare volume dirty, ibernato, journal sospetto o struttura non leggibile. Mai eseguire recovery, `ntfsfix`, `chkdsk`, rimozione del file di ibernazione o formattazione automatica.
4. Aprire la partizione in modo esclusivo dove il sistema lo consente; non iniziare se l'esclusività non è dimostrata. Copiare soltanto con nuovo nome, senza sovrascrivere file esistenti. Nessun'altra app deve montare lo stesso volume durante l'operazione. La prova su dispositivo deve ancora verificare il comportamento reale dell'apertura esclusiva.
5. Controllare ogni valore restituito dalla libreria, numero di byte e sincronizzazione. Chiudere il writer, riaprire in sola lettura, confrontare dimensione e hash del file sul disco con la sorgente. Mostrare successo solo dopo completamento, flush ed espulsione normale. In caso d'errore, lasciare il disco in stato da verificare: non dichiarare riuscita né riparare automaticamente.
6. Non usare `ntfscp` come motore finale: la prova usa questa utility su immagini, ma il suo sorgente può impostare un risultato di successo dopo l'uscita anticipata dal ciclo di scrittura. Serve un adattatore che propaghi ogni errore e una verifica indipendente.

## Criteri prima di usare la scrittura su dati importanti

- Immagini sacrificabili con file piccoli, grandi, vuoti, Unicode, sparsi e compressi; verifica byte per byte e ispezione delle strutture NTFS da Windows.
- Iniezione di errori su lettura, scrittura, sincronizzazione, disco pieno, scollegamento e arresto del processo in ogni punto. Nessun falso successo; esito chiaro e possibilità di ripresa senza sovrascrivere l'originale.
- Test su unità USB sacrificabile con backup verificato, quindi controllo `chkdsk` su Windows e hash dopo ogni scenario. Ripetere su M1/macOS 15.4 e su Apple Silicon recente.
- Mai promettere assenza assoluta di stati inconsistenti durante perdita di alimentazione o scollegamento. Se i test non danno garanzie sufficienti, le scritture NTFS dirette restano disabilitate e si usa Windows.

## Perché non montare con macFUSE ora

Il backend FSKit di macFUSE è gratuito, gira in spazio utente e non richiede sicurezza di avvio ridotta, ma una [segnalazione aperta](https://github.com/macfuse/macfuse/issues/1192) descrive il fallimento del montaggio `ntfs-3g` anche su macOS 27. Il backend kernel richiede [Reduced Security su Apple Silicon](https://github.com/macfuse/macfuse/wiki/Getting-Started). Nessuno dei due entra nel percorso iniziale per i dati importanti.
