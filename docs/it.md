# Keyglow — guida rapida

Keyglow è un'app macOS nativa per **Keychron Q6 Max ISO**, con layout italiano e manopola. Permette di cambiare gli RGB via Bluetooth con il firmware personalizzato e di modificare la configurazione completa via USB. È un progetto indipendente da Keychron.

## Installazione e primo avvio

Servono un Mac Apple Silicon, macOS 13 o successivo e, per compilare, Xcode/Command Line Tools con Swift 6:

```sh
zsh scripts/build-app.sh
open dist/Keyglow.app
```

Sposta l'intera **Keyglow.app** in Applicazioni o nella cartella che preferisci. Risorse e icona sono dentro l'app; il progetto sorgente non serve per eseguirla. Preferenze e backup restano nello spazio utente di macOS. Il vecchio identificatore delle preferenze è conservato per mantenere i dati di Tastiera.

Al primo avvio, la procedura guidata spiega gli accessi e ne verifica lo stato. Per il collegamento HID, abilita Keyglow in **Impostazioni di Sistema → Privacy e sicurezza → Monitoraggio input**. L'app può chiedere l'accesso e aprire le impostazioni; il consenso spetta a te. Riavvia l'app se richiesto, poi verifica nuovamente l'accesso.

Le build locali hanno una firma ad hoc e non sono notarizzate. Ricompilare può rendere necessario rimuovere la vecchia voce da Monitoraggio input e aggiungere l'app aggiornata. Il trasferimento in un'altra cartella non aggira questi controlli di macOS.

## RGB senza cavo

La Q6 Max deve avere il **firmware personalizzato v3**. Il firmware originale non riceve questi comandi. La prima installazione e gli aggiornamenti attualmente supportati richiedono USB/DFU; [leggi i limiti del firmware](firmware.md).

1. Associa la tastiera al Mac e seleziona BT.
2. In **Illuminazione**, scegli colore, effetto, luminosità e velocità.
3. Lascia attivo **Salva nella tastiera** e premi **Applica e salva RGB**.

Non serve premere fn + ○. Durante i circa cinque secondi di invio evita Caps Lock e Num Lock; prima di spegnere la tastiera attendi almeno due secondi dalla fine. Disattiva il salvataggio per una prova temporanea. I cursori modificano la bozza: non inviano comandi da soli.

Verde con effetto Respiro è stato verificato su una Q6 Max ISO reale, senza USB, anche dopo spegnimento e riaccensione. Gli altri effetti e lo spegnimento persistente hanno test automatici, ma non tutti una verifica fisica. Il trasporto non restituisce una conferma dalla tastiera: un invio accettato da macOS va distinto dal risultato visibile.

## Configurazione USB e dati

Collega USB e seleziona Cable. Usa **Leggi tastiera**, modifica la bozza, salva un profilo e applica. L'app controlla eventuali conflitti e rilegge il risultato. Mappa, macro, RGB per tasto, Mix e impostazioni avanzate usano ancora USB.

Keyglow non richiede un account e non invia telemetria. La registrazione delle macro e il test tasti sono azioni esplicite in primo piano. Avvio rapido registra solo le scorciatoie selezionate e richiede l'app aperta. I profili possono contenere dati personali: non pubblicarli nelle segnalazioni GitHub.

Il preset **Reattiva** riduce la sospensione lato tastiera con salvaguardie per la batteria. Latenza e consumi non sono ancora misurati; non garantisce la connessione immediata mentre il Mac si avvia o si risveglia.

**Aggiornamento firmware via Bluetooth:** lavoro sperimentale, non ancora disponibile per l'installazione. Non confonderlo con il controllo RGB Bluetooth, che è già verificato.

Quando manca il permesso, all’avvio Keyglow presenta la configurazione e avvia la richiesta di macOS. Se l’accesso è negato, apre direttamente Monitoraggio input. Tornando nell’app verifica lo stato senza ripetere la richiesta. La concessione resta una conferma dell’utente.
