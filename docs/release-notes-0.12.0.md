# Keyglow 0.12.0

Mac con Apple Silicon · macOS 13 o successivo · Keychron Q6 Max ISO con manopola.

## Novità

**Guida iniziale**
- Ridisegnata: percorso con icone, un titolo e una riga per passo, la tastiera supportata disegnata con la sua geometria, istruzioni numerate per Monitoraggio input.
- macOS applica Monitoraggio input solo alle app avviate dopo la concessione: la guida offre **Esci e riapri Keyglow** e riparte dal passo Accessi.
- **Continua senza accesso** per chi usa solo il cavo USB.

**Firmware**
- Riconoscimento del firmware Keyglow via USB già nella guida.
- Nuova scheda **Firmware installato** con il pulsante **Controlla firmware**: via USB legge la versione; via Bluetooth chiede al firmware Keyglow di rispondere (circa 45 secondi, senza digitare). L'ultima versione letta resta visibile.

**Bozza e profili**
- **Annulla** (⌘Z) e **Ripeti** (⇧⌘Z) per le modifiche alla bozza.
- **Aggiorna profilo** sovrascrive il profilo da cui è partita la bozza; **Svuota cestino** con conferma.
- Le copie di recupero vengono create solo quando servono e ne restano le 20 più recenti.
- I profili sono ora file in `~/Library/Application Support/Keyglow/Profiles/`. La migrazione è verificata e la copia nelle preferenze non viene cancellata.

**Illuminazione**
- Selettore colore accanto ai campi HEX in Mix e Indicatori, limiti applicati ai campi numerici.
- Menu **Seleziona gruppo**: lettere, modificatori, riga funzione, navigazione, tastierino, righe.

**App**
- Impostazioni facoltative, spente finché non le attivi: avviso di batteria scarica, apertura al login, icona nella barra dei menu con batteria, colori rapidi e profili.
- **Controlla aggiornamenti…** nel menu Keyglow: una sola richiesta all'elenco pubblico delle release, solo quando la scegli.
- Una sola copia dell'app in esecuzione; **Esci** funziona anche con la guida aperta.
- Barra laterale con stato della tastiera più chiaro; testi delle pagine Firmware e Connessione più leggibili.

## Da sapere

- Per comunicare con la tastiera serve il permesso **Monitoraggio input**, che concedi tu in Impostazioni di Sistema. Chi aggiorna da una versione precedente deve rimuovere la vecchia voce Keyglow con "−" e aggiungere di nuovo l'app, perché la firma è cambiata.
- Colori ed effetti via Bluetooth richiedono il **firmware Keyglow** sulla tastiera. La prima installazione si fa via USB dalla pagina Firmware; il percorso integrato è verificato con test software ma non ancora provato fisicamente dall'inizio alla fine.
- Durante un aggiornamento firmware o un controllo via Bluetooth usa solo il mouse.
- Versione sperimentale, progetto indipendente non affiliato a Keychron.

---

# Keyglow 0.12.0 (English)

Apple Silicon Mac · macOS 13 or later · Keychron Q6 Max ISO with knob.

- **Setup guide** redesigned, with a quit-and-reopen step for Input Monitoring that resumes where you left, and a USB-only path.
- **Firmware**: Keyglow firmware is recognized over USB in the guide; a new **Installed Firmware** card with **Check Firmware** (USB reads the version; Bluetooth asks the Keyglow firmware to answer, about 45 seconds without typing).
- **Draft and profiles**: Undo and Redo, Update Profile, Empty Trash, fewer and capped recovery copies, profiles stored as files with a verified migration.
- **Lighting**: color pickers next to HEX fields, numeric limits, a Select Group menu.
- **App**: optional low-battery notice, open at login and menu bar item (all off by default); Check for Updates on request; a single running copy; Quit works with the guide open.

Input Monitoring must be granted by you in System Settings; when updating from an earlier build, remove the old Keyglow entry with "−" and add the app again. Bluetooth colors need the Keyglow firmware, first installed over USB. Experimental, independent project, not affiliated with Keychron.
