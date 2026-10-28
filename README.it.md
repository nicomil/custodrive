<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icona di Custodrive">
</p>

<h1 align="center">Custodrive</h1>

<p align="center">
  <b>Copie verificate sui tuoi dischi esterni.</b><br>
  Leggi e scrivi su dischi e chiavette Windows (NTFS) dal Mac, con ogni
  operazione verificata.
</p>

<p align="center">
  Mac Apple Silicon · macOS 15.4 o successivo · gratuita, senza driver né abbonamenti
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Italiano</b> · <a href="README.es.md">Español</a>
</p>

---

macOS legge i dischi NTFS ma non ci scrive. Custodrive ti permette di
copiare foto e video, creare cartelle, rinominare, spostare ed eliminare su
dischi formattati da Windows, con un'interfaccia simile al Finder. Le copie
vengono rilette e verificate. Un'interruzione può comunque danneggiare il
filesystem: il segnale «da controllare» e il diario aiutano il recupero,
ma non garantiscono l'assenza di perdite. Conserva una copia dei dati importanti.

Interfaccia disponibile in **inglese (predefinito), italiano e spagnolo**.
Usa il menu **Lingua** (icona del globo) nella barra, oppure **Custodrive →
Impostazioni…**, poi riavvia l’app per applicare la scelta. Sessioni di
modifica e copie in corso proseguono normalmente. Le immagini mostrano
l’interfaccia italiana.

<p align="center">
  <img src="docs/images/01-browser.png" width="780" alt="Custodrive: dischi a sinistra, contenuto del disco a destra">
</p>

## Indice

- [Primi passi](#primi-passi)
- [Funzioni](#funzioni)
- [Come ti protegge](#come-ti-protegge)
- [Scorciatoie](#scorciatoie)
- [Problemi comuni](#problemi-comuni)
- [Requisiti e limiti](#requisiti-e-limiti)
- [In arrivo](#in-arrivo)
- [Per sviluppatori](#per-sviluppatori)

## Primi passi

### 1. Installa

1. Apri `Custodrive-1.1.0.dmg` e trascina **Custodrive** sulla cartella
   **Applicazioni**.
2. Apri Custodrive dalla cartella Applicazioni.

**La prima volta su un nuovo Mac** macOS la blocca con «non è possibile
verificare lo sviluppatore»: Custodrive non è distribuita con un certificato
Apple Developer. Chiudi l'avviso, poi vai in **Impostazioni di Sistema →
Privacy e sicurezza** e, in fondo alla pagina, premi **Apri comunque**
accanto a «Custodrive». In alternativa, dal Terminale:

```sh
xattr -dr com.apple.quarantine /Applications/Custodrive.app
```

Serve una sola volta per Mac.

### 2. Collega un disco e sfoglialo

Collega un disco o una chiavetta NTFS: compare a sinistra, sotto **Dischi
esterni**. Selezionalo e sfoglia le cartelle come nel Finder. Finché non
modifichi niente, il disco resta montato in sola lettura ed è visibile
anche nel Finder.

<p align="center">
  <img src="docs/images/02-folder.png" width="780" alt="Una cartella di foto aperta in Custodrive">
</p>

### 3. Copia e modifica

Trascina file o cartelle dal Finder nella finestra, oppure sopra una
cartella. Alla prima modifica macOS chiede la **password di amministratore
una sola volta**. Da quel momento il disco è in **modifica attiva**:
riservato a Custodrive, con ogni operazione immediata.

<p align="center">
  <img src="docs/images/03-edit-session.png" width="780" alt="Modifica attiva: il disco è riservato a Custodrive">
</p>

### 4. Termina ed espelli

Quando hai finito premi **Termina modifiche**: il disco torna in sola
lettura e visibile nel Finder. Poi usa **Espelli** prima di scollegarlo.
Espelli, o la chiusura dell'app, terminano anche le modifiche da soli.

## Funzioni

### Sfogliare
- **Barra laterale** con tutti i dischi esterni e il loro stato (sola
  lettura, modifica attiva, verifica necessaria).
- **Elenco a colonne** (nome, dimensione, data), ordinabile con un clic
  sull'intestazione; le cartelle stanno sempre in cima.
- **Percorso cliccabile**, pulsanti Indietro, Avanti e Cartella superiore.
- **Doppio clic** per aprire una cartella o un file.
- **Quick Look** con la barra spaziatrice, come nel Finder.
- Durante **modifica attiva**, aprire un file chiede dove salvare una copia
  sul Mac. Le modifiche nell'editor restano lì: per riportarle sul disco NTFS
  occorre copiarle con Custodrive. Le anteprime Quick Look sono temporanee
  e in sola lettura.

### Copiare dal Mac
- Trascina file e **cartelle intere** dal Finder: tutte le sottocartelle
  vengono ricreate. I file di servizio del Mac (`.DS_Store`, `._*`) vengono
  saltati; i link simbolici non vengono seguiti.
- Oppure usa il pulsante **Copia qui file dal Mac…**, il tasto destro sui
  file nel Finder → **Servizi → Copia su disco NTFS con Custodrive**, o
  trascina i file sull'**icona di Custodrive nel Dock**. I file finiscono
  nella cartella aperta nell'app. Il nome del servizio Finder segue la lingua del sistema.
- Ogni file viene **riletto dal disco e confrontato** (SHA-256) con
  l'originale prima di comparire con il suo nome.
- **File già presenti**: Custodrive chiede se **sostituirli** o
  **saltarli**. Il vecchio file resta finché il nuovo non è stato verificato.
- Le **copie grandi** avanzano a lotti (1000 file o 8 GB alla volta), con
  una sola barra, la velocità e il tempo rimanente.

<p align="center">
  <img src="docs/images/04-copy-progress.png" width="780" alt="Copia in corso con barra di avanzamento, tempo rimanente e pulsante Annulla">
</p>

### Organizzare
- **Nuova cartella** (⇧⌘N): viene creata e il nome è subito pronto da
  scrivere.
- **Rinomina**: seleziona e premi Invio, poi scrivi direttamente
  nell'elenco. Puoi cambiare anche solo maiuscole e minuscole.
- **Sposta**: trascina elementi sopra una cartella, oppure ⌘X e poi ⌘V
  nella cartella di destinazione. È immediato, i dati non vengono ricopiati.
- **Elimina** (⌘⌫): file e cartelle con tutto il contenuto. Su NTFS non c'è
  un Cestino, quindi Custodrive chiede sempre conferma.
- **Menu contestuale** con il tasto destro, con tutte le azioni.

<p align="center">
  <img src="docs/images/05-delete-confirm.png" width="260" alt="Conferma di eliminazione">
</p>

### Coda e annullamento
- Quello che trascini mentre una copia è in corso si mette **in coda**
  sotto la stessa barra.
- **Annulla** richiede l'arresto della copia:
  - se il ripristino riesce, il lotto in corso viene tolto e il disco resta pulito;
  - i lotti già completati restano sul disco, verificati;
  - la coda viene svuotata.

## Come ti protegge

Custodrive applica queste misure per rilevare errori e limitare i danni:

1. **Il disco viene segnato «da controllare»** (dirty bit di NTFS) prima di
   ogni modifica. Il segno viene tolto solo quando l'operazione è finita e
   verificata. Dopo un'interruzione, il segno richiede un controllo su
   Windows; l'esito di `chkdsk` dipende dai danni presenti.
2. **Niente viene sovrascritto sul posto.** I file nuovi vengono scritti a
   parte e riletti; solo dopo prendono il loro nome. Una sostituzione tiene
   da parte il vecchio file finché il nuovo non è al suo posto.
3. **Un diario di recupero** registra sostituzioni, spostamenti e rinomine.
   Dopo il controllo del filesystem, Custodrive verifica il diario prima
   di completare o annullare l'operazione. Se nomi, identità o contenuti
   risultano ambigui, rifiuta il recupero conservando quanto trova.
4. **Dischi a rischio rifiutati.** Custodrive non scrive su dischi con
   Windows in ibernazione o Avvio rapido, con il journal non chiuso o già da
   controllare, e spiega il motivo.
5. **File di sistema protetti.** `$MFT`, `System Volume Information`,
   junction, link simbolici e file cifrati non vengono mai toccati né
   seguiti.

I test automatici includono errori I/O e interruzioni simulate. I casi
illeggibili o da riparare restano **inconclusivi** finché non verificati su
Windows. Le prove storiche su Windows e USB riguardano versioni precedenti:
non certificano automaticamente il motore attuale. Stato e limiti in
[docs/sviluppo.md](docs/sviluppo.md).

## Scorciatoie

| Azione | Tasti |
|---|---|
| Apri cartella o file | doppio clic, ⌘↓ |
| Cartella superiore | ⌘↑ |
| Indietro / Avanti | ⌘[ / ⌘] |
| Quick Look | Spazio |
| Rinomina | Invio |
| Nuova cartella | ⇧⌘N |
| Copia qui file dal Mac | ⇧⌘O |
| Taglia (per spostare) / Incolla | ⌘X / ⌘V |
| Elimina | ⌘⌫ |

## Problemi comuni

**«Windows non ha chiuso correttamente il disco (journal NTFS aperto)».**
Il disco è stato staccato da Windows senza rimozione sicura. Ricollegalo a
Windows, usa **Rimozione sicura dell'hardware**, poi riprova sul Mac.

**«Windows è in ibernazione o con Avvio rapido attivo».** Spegni Windows
completamente (non solo sospensione), oppure disattiva l'Avvio rapido.

**«Il disco va controllato su Windows».** Un'operazione è stata
interrotta. Prima conserva una copia dei dati ancora accessibili. Su una
copia sacrificabile, o dopo aver salvato i dati, apri il Prompt dei comandi
Windows come amministratore ed esegui `chkdsk X: /f`, dove X è la lettera
del disco. `chkdsk` modifica il filesystem e non garantisce il recupero.
**Se Windows propone di formattare il disco, rifiuta.** Custodrive può
riprendere solo quando il volume supera i controlli; un diario ambiguo
richiede verifica manuale. Non cancellare i file `.OpenHDD-*` per forzarla.

**«Recupero sospeso — scritture bloccate».** L'app mostra il motivo, la voce
del diario e i percorsi attesi; non afferma di aver ritrovato i file spostati
da Windows. Puoi sfogliare anche i temporanei, **Salvare il file selezionato**
su un altro disco, oppure **Aprire nel Finder** in sola lettura per copiare
cartelle. **Salva rapporto** conserva la diagnostica, inclusi nomi privati.
**Controlla di nuovo** rivalida il volume senza scrivere: le modifiche tornano
disponibili solo se tutti i controlli passano. Se l'ambiguità resta, conserva
originale e diario e richiedi assistenza; non esiste uno sblocco forzato.

**Non vedo il disco nel Finder.** Durante la modifica attiva il disco è
riservato a Custodrive: premi **Termina modifiche**.

## Requisiti e limiti

- Mac con chip Apple (M1 o successivi), macOS 15.4 o successivo.
- Dischi e chiavette **NTFS** esterni. Per APFS, exFAT e FAT usa il Finder.
- La scrittura avviene dentro Custodrive, non direttamente dal Finder: il
  Finder vede il disco in sola lettura.
- Non si modificano file «sul posto» (per esempio aprire un documento sul
  disco e salvarlo): si copia, si sostituisce, si sposta.
- File NTFS compressi o cifrati non vengono scritti.

## In arrivo

Custodrive vuole diventare il custode dei tuoi dischi, non solo un ponte
verso NTFS. Prossime funzioni previste:

- **Clonazione** di dischi e chiavette, per avere sempre una copia pronta
  se un'unità si guasta.
- **Sincronizzazione** tra un disco e una cartella del Mac (o un altro
  disco), con verifica dei contenuti.
- **Controllo di salute** delle unità, per accorgersi in tempo di quelle
  che stanno per cedere.

## Per sviluppatori

```sh
Scripts/build-local-app.sh    # compila Build/Custodrive.app
Scripts/package-app.sh        # crea Build/Custodrive-1.1.0.dmg da condividere
sh Tests/run-localization-test.sh  # verifica i tre cataloghi lingua
```

Build, motore da riga di comando, test automatici, collaudo su Windows e
storia del progetto: [docs/sviluppo.md](docs/sviluppo.md). Il motore NTFS si
basa su [NTFS-3G](vendor/README.it.md).

I testi UI sono in `Resources/Localization/{en,it,es}.lproj`. Inglese
predefinito e di riserva. `CustodriveLanguage` salva la scelta; il riavvio
la applica a SwiftUI e ai dialoghi AppKit. Diagnostica tecnica, percorsi e
nomi dei file conservano i valori originali.

## Licenza

Custodrive è software libero, distribuito sotto la
[GNU General Public License, versione 2 o (a tua scelta) qualunque versione successiva](LICENSE)
(GPL-2.0-or-later). Il motore di copia usa [NTFS-3G](vendor/README.it.md) di
Tuxera, con la stessa licenza; i sorgenti originali di NTFS-3G sono in
`vendor/`. Custodrive è fornito senza alcuna garanzia: tieni una copia dei
dati importanti.
