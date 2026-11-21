# Keyglow — guida rapida

Keyglow è un'app macOS nativa per **Keychron Q6 Max ISO**, con layout italiano e manopola. Permette di cambiare gli RGB via Bluetooth con il firmware personalizzato e di modificare la configurazione completa via USB. È un progetto indipendente da Keychron.

## Installazione e primo avvio

Scarica il DMG più recente dalla **[pagina delle release](https://github.com/FrancoisLampasona/Keyglow-Tool_for_Keychron_keyboard/releases)**, aprilo e trascina Keyglow in Applicazioni. Avvia l’app da lì ed espelli il disco. Servono un Mac Apple Silicon e macOS 13 o successivo. Le note di ogni release dicono se il DMG contiene anche firmware e strumenti USB per la prima installazione. Novità della 0.12.0: [note di rilascio](release-notes-0.12.0.md).

È una versione sperimentale. Dalla 0.12.0 l’app è firmata con un certificato Developer ID Apple; le note di ogni release dicono se il DMG è anche notarizzato. Un DMG notarizzato si apre senza avvisi; uno non notarizzato viene bloccato da macOS finché non approvi quella singola app in Impostazioni di Sistema → Privacy e sicurezza. Le release fino alla 0.11.1 avevano firma locale e non erano notarizzate. La nuova prima installazione guidata è verificata tramite test software, ma non ancora provata fisicamente dall’inizio alla fine. La prima scrittura del loader non resiste a un’interruzione di alimentazione: l’app richiede una conferma esplicita prima di iniziare.

Per compilare dai sorgenti servono Xcode/Command Line Tools con Swift 6:

```sh
zsh scripts/build-app.sh
open dist/Keyglow.app
```

Sposta l'intera **Keyglow.app** in Applicazioni o nella cartella che preferisci. Risorse e icona sono dentro l'app; il progetto sorgente non serve per eseguirla. Preferenze e backup restano nello spazio utente di macOS. Il vecchio identificatore delle preferenze è conservato per mantenere i dati di Tastiera.

Al primo avvio una procedura in quattro passi verifica **Tastiera → Accessi → Firmware → Riepilogo**:

1. Collega la tastiera. Keyglow legge il modello e la variante; questa versione supporta **Q6 Max ISO con manopola**, rappresentata con legende italiane. Non propone il firmware ISO per ANSI o altri modelli. Con più tastiere devi scegliere; senza tastiera puoi esplorare la bozza.
2. Per comunicare tramite HID serve **Monitoraggio input**. La richiesta parte nella pagina Accessi soltanto se manca il permesso. Abilita Keyglow in Impostazioni di Sistema → Privacy e sicurezza. macOS applica il permesso solo alle app avviate dopo averlo concesso: usa **Esci e riapri Keyglow** e la guida riprende dal passo Accessi. Se usi solo il cavo puoi scegliere **Continua senza accesso**: gli RGB via Bluetooth restano non disponibili. Se è già consentito non occorre autorizzarlo di nuovo.
3. Il firmware originale non riceve RGB da Keyglow via Bluetooth. Scegli se preparare il firmware personalizzato, dichiarare quello già installato o usare per ora USB. La dichiarazione non equivale a una lettura del firmware.
4. Il riepilogo apre la destinazione corretta. **La prima installazione avviene nella pagina Firmware dell’app**, con backup, autorizzazione della chiave prima che la tastiera smetta di scrivere, istruzioni DFU, riepilogo da confermare, scrittura e verifica, riavvio e ripristino del profilo. Serve USB per questa prima volta. L’apertura di una pagina non installa nulla.

Puoi riaprire il percorso dal menu **Keyglow → Configura tastiera e accessi…**. Bluetooth di sistema e Portachiavi richiedono eventuali consensi separati quando usi le rispettive funzioni, non tutti al primo avvio.

Per le compilazioni ripetute è disponibile una [firma locale stabile](local-signing.md), conservata nel Portachiavi. Il passaggio dalla vecchia firma può richiedere un consenso iniziale; le build successive devono mantenere la stessa identità. Senza questa configurazione le build usano una firma ad hoc, che cambia a ogni ricompilazione. Le build locali non sono notarizzate. Il trasferimento in un'altra cartella non aggira questi controlli di macOS. Quando il permesso è già valido, l'app verifica automaticamente la Q6 Max collegata in sola lettura; una tastiera scollegata viene distinta da un permesso negato.

Tutta la riga della sidebar è cliccabile; puoi anche usare ⌘1–9. La finestra ricorda le dimensioni e si adatta allo schermo, fino a 900 × 640. Nelle finestre strette, Illuminazione mette in primo piano colore ed effetto e permette di espandere l’anteprima della tastiera. Dal menu **Finestra** scegli **Dimensione compatta** o **Dimensione comoda**.

## Lingua dell’app

Keyglow è disponibile in **italiano, inglese e francese**. Il menu con il globo è nel primo avvio e in fondo alla barra laterale. Scegli **Italiano**, **English** o **Français**: l’interfaccia cambia subito, senza riaprire l’app, e la scelta resta salvata sul Mac. L’italiano è la lingua iniziale.

La lingua dell’interfaccia non cambia il layout fisico ISO italiano, le assegnazioni dei tasti, i nomi dei profili o il contenuto delle macro. Le traduzioni sono incluse nell’app e funzionano senza Internet. Le finestre gestite da macOS possono seguire la lingua del sistema.

## Batteria

La barra laterale mostra la percentuale letta dalla Q6 Max via Bluetooth. Dalla 0.11.1 si aggiorna ogni minuto finché Keyglow è aperta, anche in background o ridotta nel Dock. La connessione viene ricontrollata circa ogni cinque secondi. Il monitoraggio si ferma durante le operazioni, nella pagina Firmware e quando il Mac è in sospensione; riprende automaticamente quando possibile. Clicca la batteria per vedere l’ora della lettura o aggiornare il dato. Il primo accesso Bluetooth viene richiesto soltanto premendo **Leggi batteria**; un consenso già valido viene riutilizzato.

In **Connessione → Impostazioni dell'app** trovi tre opzioni, tutte spente finché non le attivi: l'avviso di batteria scarica (una notifica sotto il 20% e una sotto il 10%, solo con Keyglow aperta e una lettura recente; il consenso alle notifiche viene chiesto quando attivi l'opzione), **Apri Keyglow al login** e **Mostra Keyglow nella barra dei menu**. Con l'icona nella barra dei menu, chiudere la finestra non chiude l'app: batteria e Avvio rapido restano attivi, e la finestra si riapre da **Apri Keyglow** o dal Dock. I colori del menu vengono inviati via Bluetooth solo quando scegli una voce e solo se l'accesso è già verificato; i profili vengono caricati soltanto nella bozza.

In Cable compare **Batteria —**: questa lettura richiede il collegamento BT. Un dato vecchio è indicato come precedente; nessuna percentuale viene stimata. Lo stato di ricarica non è esposto dal servizio letto. Una pausa durante un’altra operazione conserva il dato valido e non viene mostrata come un errore; la lettura riprende automaticamente quando possibile.

Il ciclo completo **Bluetooth → USB → Bluetooth** è stato verificato sulla Q6 Max reale con Keyglow 0.11.0, senza riaprire l’app e senza premere Rileva o Aggiorna batteria. In Bluetooth compariva **88%**; passando a Cable sono comparsi **USB rilevata** e **Batteria —**. Tornando in Bluetooth è arrivata una nuova lettura del **92%**, seguita automaticamente da **91%** il minuto successivo. Profili e configurazione locale sono rimasti invariati. La prova è stata svolta con l’app in primo piano: [dettagli della verifica](dmg-validation.md#physical-bluetooth--usb--bluetooth-cycle--0110).

Con la **0.11.1** la prova è riuscita anche in background: batteria **92% → 90%**, passaggio a USB con percentuale rimossa, poi ritorno al Bluetooth con una nuova lettura del **93%**. Gli eventi locali confermano che Keyglow non era l’app attiva. [Prova e limiti](dmg-validation.md#background-monitoring--0111-build-25).

## RGB senza cavo

La Q6 Max deve avere il **firmware personalizzato v3**. Il firmware originale non riceve questi comandi. La prima installazione richiede USB/DFU; [leggi i limiti del firmware](firmware.md).

1. Associa la tastiera al Mac e seleziona BT.
2. In **Illuminazione**, scegli colore, effetto, luminosità e velocità.
3. Lascia attivo **Salva nella tastiera** e premi **Applica e salva RGB** (oppure **Invia ora** con anteprima attiva).

Non serve premere fn + ○. Durante i circa cinque secondi di invio manuale evita Caps Lock e Num Lock; prima di spegnere la tastiera attendi almeno due secondi dalla fine. Disattiva il salvataggio per una prova temporanea.

La 0.8 aggiunge **Anteprima sulla tastiera**: attivandola, le modifiche a colori ed effetti vengono inviate automaticamente via Bluetooth. Durante un invio viene conservata soltanto l'ultima modifica in attesa; a fine modifica viene salvato il risultato se il salvataggio è attivo. Dalla 0.8.2 l'app ricorda la scelta dell'anteprima, inizialmente disattivata. L'apertura non invia colori: occorre una nuova modifica. L'invio rapido a 20 ms resta sperimentale; blu Respiro è stato confermato sulla Q6 Max reale senza premere Applica, con USB scollegata. Il risultato non è istantaneo.

Verde con effetto Respiro è stato verificato su una Q6 Max ISO reale, senza USB, anche dopo spegnimento e riaccensione. Gli altri effetti e lo spegnimento persistente hanno test automatici, ma non tutti una verifica fisica. Il trasporto non restituisce una conferma dalla tastiera: un invio accettato da macOS va distinto dal risultato visibile.

## Configurazione USB e dati

Collega USB e seleziona Cable. Usa **Leggi tastiera**, modifica la bozza, salva un profilo e applica. L'app controlla eventuali conflitti e rilegge il risultato. Mappa, macro, RGB per tasto, Mix e impostazioni avanzate usano ancora USB.

I profili salvati si trovano in `~/Library/Application Support/Keyglow/Profiles/profiles.json` (con `profiles.previous.json` come copia precedente). Al primo avvio della versione che introduce i file, Keyglow li copia dalle preferenze, li rilegge e li confronta; la vecchia copia nelle preferenze non viene cancellata e viene riusata se i file mancano o non sono leggibili. I backup creati prima di **Applica via USB** vanno in `~/Library/Application Support/Keyglow/Backups/` (restano i 50 più recenti); quelli delle versioni precedenti in `Tastiera/Backups/` non vengono toccati.

Keyglow non richiede un account e non invia telemetria. L'unica richiesta di rete è il comando **Keyglow → Controlla aggiornamenti…**: solo quando lo scegli, l'app legge l'elenco pubblico delle release del progetto su GitHub, senza inviare dati personali e senza scaricare o installare nulla. La registrazione delle macro e il test tasti sono azioni esplicite in primo piano. Avvio rapido registra solo le scorciatoie selezionate e richiede l'app aperta. I profili possono contenere dati personali: non pubblicarli nelle segnalazioni GitHub.

Il preset **Reattiva** riduce la sospensione lato tastiera con salvaguardie per la batteria. Latenza e consumi non sono ancora misurati; non garantisce la connessione immediata mentre il Mac si avvia o si risveglia.

**Aggiornamento firmware via Bluetooth:** la 0.8 include il percorso sperimentale dall'app, con verifica della chiave proprietario, blocchi confermati e controllo del firmware dopo il riavvio. La prima installazione USB del loader è riuscita su una Q6 Max ISO e il profilo è stato ripristinato e riletto. Il passaggio dalla build 8 alla 9 è riuscito via Bluetooth su quella tastiera, riprendendo i blocchi salvati: finalizzazione e lettura autenticata dopo il riavvio a 20 ms. Il trasferimento ha richiesto riprese con intervalli di 20 e 80 ms; non è una prova di invio completo e ininterrotto a 20 ms. Durante verifica e aggiornamento usa solo il mouse: tasti e manopola interrompono il trasferimento. La barra mostra i dati confermati dalla tastiera e puoi riprendere i blocchi salvati. Non aggiorna il modulo radio. Chiave privata, loader personalizzato e backup completi non vanno pubblicati.

La richiesta di macOS parte al passo Accessi della configurazione. Se l’accesso è negato, apre Monitoraggio input; al ritorno verifica lo stato senza ripetere la richiesta. La concessione resta una conferma dell’utente.

## Profili e navigazione

**Personali** raccoglie le copie salvate da te; **Recupero** separa quelle create prima di leggere o sostituire la bozza. Rimuovere un profilo lo sposta nel **Cestino**, da cui puoi ripristinarlo anche dopo aver riaperto l’app. Non vengono cancellati automaticamente i profili più vecchi quando ne salvi un altro.

Caricare un profilo aggiorna la bozza locale. Aprire RGB per tasto o Mix non cambia da solo l’effetto: scegli esplicitamente la modalità quando vuoi usarla. Queste sezioni si applicano via USB e non generano anteprime Bluetooth.

La pagina Firmware conserva il file scelto e la verifica durante la navigazione. Il percorso principale segue **Scegli file → Verifica → Installa**; diagnostica e preparazione iniziale sono sezioni espandibili.

## Problemi frequenti

- **Il permesso resta “Da abilitare” dopo averlo attivato.** macOS applica Monitoraggio input solo alle app avviate dopo la concessione: usa **Esci e riapri Keyglow**.
- **Keyglow è attivo in Monitoraggio input ma l’app non lo vede.** La voce appartiene a una copia o a una build precedente. Rimuovila con **−**, aggiungi di nuovo l’app con **+**, poi esci e riapri.
- **Il controllo del firmware via Bluetooth è lento o non riceve risposta.** Dura circa 45 secondi per costruzione: non digitare e non toccare la manopola. Dopo una richiesta senza risposta il pulsante conta alla rovescia per un minuto. Una mancata risposta non prova che ci sia il firmware originale: per la certezza collega il cavo e ripeti il controllo.
- **I colori non cambiano via Bluetooth.** Serve il firmware Keyglow; l’invio RGB non ha conferma dalla tastiera, quindi controlla la tastiera stessa.
- **Uscita.** Gira una sola copia di Keyglow. Con l’icona nella barra dei menu attiva, chiudere la finestra non chiude l’app: usa **Esci da Keyglow**.
