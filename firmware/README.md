# RGB Bluetooth sperimentale — Q6 Max ISO

Il firmware Keychron originale **non contiene questo ricevitore**. Questi sorgenti aggiungono il controllo di colore, effetto, luminosità e velocità attraverso gli indicatori HID standard della connessione Bluetooth. Richiedono un primo flash del firmware personalizzato via USB. Nessun flash o modifica della tastiera viene eseguito dai file o dai test in questa cartella.

Il decoder e il bridge QMK sono verificati su Mac con AddressSanitizer e UndefinedBehaviorSanitizer. I test del bridge usano API simulate: non dimostrano il passaggio dei tre bit nel modulo radio della tastiera. La compilazione ARM e la prova fisica sono verifiche distinte; lo stato dei relativi artefatti va controllato nel progetto principale.

## Stato e controllo diretto v3

Il firmware **0.6/v3 è stato installato e verificato su una Q6 Max ISO**: verde Respiro ricevuto senza fn + ○ e conservato dopo spegnimento/riaccensione, USB scollegata e digitazione normale. Questa verifica non copre ogni effetto o revisione hardware. [Compatibilità e limiti](../docs/firmware.md).

V3 riconosce automaticamente i pacchetti sul collegamento Bluetooth connesso: non occorre Fn + ○. L’app invia soltanto dopo un’azione esplicita dell’utente, senza scrivere a ogni movimento dei cursori. La configurazione può essere temporanea (`CMD=03`) oppure persistente (`CMD=04`). Ogni comando conserva il formato da 13 byte e l’intervallo 80 ms:

```
4B 52 47 42 03 CMD MODE H S V SPEED CRC_H CRC_L
```

Modo 0 richiede H/S/V/SPEED tutti zero; 1–22 usa la stessa tabella v2. CRC, validazione e timeout restano obbligatori. Il nuovo ricevitore accetta v1/v2 solo con il vecchio armamento; il decoder 0.5 rifiuta v3 anche se armato. Il firmware originale non contiene alcun decoder di questo progetto. Non esistono comandi OTA o scritture firmware nel protocollo RGB.

V3 accoda il comando fino alla scansione matrice successiva. Il salvataggio è sincrono in quel passaggio: copia soltanto enable, effetto, HSV e velocità nei byte RGB core, preserva flag e byte riservati già memorizzati e salta la scrittura se uguali. Disabilita anche il singolo byte demo salvato, se necessario, perché la demo al riavvio sovrascriverebbe l’effetto scelto. Non salva mappa, macro, timer, indicatori, per-tasto o Mix. Attendere il completamento dell’invio e altri 2 secondi prima di spegnere. Non è una transazione resistente a una perdita di alimentazione durante la scrittura; usa la memoria emulata e le API del firmware esistente.

Il canale non restituisce conferma di salvataggio: il successo macOS resta distinto dalla prova fisica dopo spegnimento/riaccensione. Il CRC non autentica l’app; qualunque software autorizzato sul computer associato che conosca questo protocollo può inviare RGB. USB/2,4 GHz e stati radio non connessi annullano ricezione e comando pendente.

Gli overlay Caps/Num sono filtrati soltanto durante un prefisso riconosciuto, il pacchetto e una coda di 600 ms; fuori da queste finestre restano normali. Prima del riconoscimento del prefisso può esserci un breve cambiamento visivo di quei due indicatori. Questo non cambia gli stati logici Caps/Num del Mac; evitare di premerli durante i circa 5 secondi di invio.

## Utilizzo legacy v1/v2

1. Sulla Q6 Max ISO in modalità Bluetooth, tenere premuto **Fn**, poi il **primo tasto grafico sopra il tastierino numerico** per due secondi. È il tasto con il cerchio sul layout italiano; il riconoscimento avviene dalla posizione fisica `[0,17]`, insieme a Fn `[5,12]`, senza cambiare la keymap VIA salvata.
2. Rilasciare i tasti e inviare una configurazione dall'app entro 30 secondi. Un frame v2 impiega circa 4,2 secondi. Il ricevitore accetta un solo comando valido per armamento.
3. Per un altro invio, ripetere la combinazione. Ripetere la combinazione mentre il ricevitore è ancora armato annulla la finestra. Un mantenimento continuo non riarma e non prolunga la finestra.

La pressione breve non arma. Premere prima il tasto grafico e solo dopo Fn non arma. La combinazione non viene intercettata in USB/2,4 GHz. Il press/release del tasto grafico viene consumato se premuto con Fn già abbassato in Bluetooth; gli altri tasti mantengono il comportamento ordinario. Lo stato fisico è letto dalla matrice anche se VIA cambia il keycode assegnato alla posizione.

Le modifiche RGB v1/v2 sono **temporanee**, tramite API `_noeeprom`: un riavvio o altri percorsi Keychron che ricaricano la configurazione possono ripristinare le impostazioni salvate. Il bridge non resetta EEPROM, macro, keymap, associazioni Bluetooth o modulo radio. Questo non garantisce la conservazione durante un flash: il codice VIA originale può reinizializzare keymap e macro quando cambia la data di compilazione, e il binario attraversa la regione della EEPROM emulata. Servono backup e un ripristino controllato del profilo. Ogni comando RGB v1/v2 valido interrompe soltanto in RAM l’eventuale modalità demo, che altrimenti forzerebbe nuovamente Mix RGB; il flag salvato non viene scritto.

## Preset opzionale di reattività Bluetooth

Il componente `qmk_responsive_idle.c` aggiunge il veto `q6_lpm_is_idle_user()` all’hook della Q6 `lpm_is_kb_idle()`, preservando i controlli originali dell’indicatore di accensione e del backlight, per impedire l'ingresso del **microcontrollore della tastiera** in STOP soltanto quando tutte queste condizioni sono vere:

- Selettore in Bluetooth e stato radio `WT_CONNECTED`.
- Timeout radio configurato esattamente a **65520 secondi = 1092 minuti = 18 ore e 12 minuti**.
- Almeno una lettura batteria reale e plausibile dall'ultima inizializzazione; campionamento iniziale terminato.
- Batteria non dichiarata vuota/critica e tensione superiore alla soglia Keychron `EMPTY_VOLTAGE_VALUE` (3500 mV nel target fissato).

In tutti gli altri stati il veto aggiuntivo restituisce `true`, cioè consente all’hook Q6 originale di valutare normalmente la sospensione. `power_on_indicator_timer == 0` e `!backlight_indicator_is_active()` restano condizioni necessarie anche quando il preset non è attivo. Non ordina un sonno immediato. Con batteria bassa/critica, misura iniziale assente, disconnessione, pairing, riconnessione, sospensione radio, USB o 2,4 GHz riprende il comportamento normale. Anche una tensione bassa appena misurata fa decadere il preset senza attendere i contatori del firmware.

L'opzione si seleziona dal tool impostando il preset 1092 minuti **con cavo USB e selettore fisico su Cable**. Cambiando quel timeout a un altro valore la condizione viene rimossa; per tornare esattamente alla configurazione precedente conservarne il valore prima del preset. Non vengono aggiunti comandi di protocollo o campi EEPROM: il tool usa la configurazione wireless già esistente. Il codice del veto non scrive EEPROM.

Il valore 65520 è un contratto esplicito di questo firmware: impostarlo da un altro configuratore attiva la stessa opzione. Una tastiera che avesse già quel valore memorizzato lo soddisferebbe dopo l'aggiornamento. Rimane anche un timeout radio finito, non un codice speciale che disabilita ogni sospensione.

Il veto riduce i passaggi MCU STOP mentre la tastiera è connessa. **Non garantisce che il modulo radio resti sempre sveglio, che macOS mantenga la connessione o che il Mac si risvegli.** Non cambia il firmware radio, i clock o le attese del risveglio; non invia pressioni o movimenti sintetici. Il consumo può aumentare: non è stata misurata l'autonomia di questa modalità.

La selezione Cable è rilevante: il setter wireless originale, se eseguito mentre il selettore è ancora wireless e connesso, contiene input sintetici per riavviare il timer radio anche se il comando di configurazione arriva dal cavo USB. Questo componente lascia quel codice originale intatto; il flusso del tool deve richiedere Cable prima di applicare il preset.

## Trasporto BLE3 comune a v1, v2 e v3

È un protocollo sperimentale di questo progetto, non una funzione ufficiale Keychron. Il payload HID output è la maschera LED; i bit 0–2 trasportano i simboli. V1/v2 richiedono l’armamento fisico; v3 usa il riconoscimento automatico del magic sul collegamento connesso.

| Bit | Uso |
| --- | --- |
| 0 | dato, bit meno significativo |
| 1 | dato, bit più significativo |
| 2 | clock, invertito per ogni simbolo |
| 3–7 | preservati dal mittente |

Ogni byte viene inviato in quattro simboli da due bit, nell'ordine `(byte >> 6) & 3`, `(byte >> 4) & 3`, `(byte >> 2) & 3`, `byte & 3`. Il decoder consuma un simbolo solo quando il clock cambia: un callback duplicato non aggiunge dati.

Il Mac invia prima una baseline con i tre bit inferiori a zero, aspetta 80 ms e invia il primo simbolo con clock a 1. Alterna poi il clock ogni 80 ms. La baseline può aggiungere uno zero se il vecchio clock era 1; la ricerca del magic avviene a granularità di simbolo e riallinea il frame. Il mittente usa il report output del dispositivo selezionato e ripristina la maschera originale anche in caso di errore; non simula pressioni dei tasti Caps/Num/Scroll Lock.

- CRC16/CCITT-FALSE: polinomio `0x1021`, inizializzazione `0xFFFF`, nessuna riflessione, XOR finale zero. Include magic, versione, comando e payload; viene trasmesso big-endian.
- Timeout tra simboli accettati: **400 ms**. Un frame parziale viene scartato senza modificare gli RGB; l’eventuale finestra di armamento legacy continua.
- Timeout assoluto armamento legacy: **30.000 ms**. Il traffico non lo prolunga. Un cambio di trasporto disarma immediatamente.
- Versioni, comandi e modalità sconosciute, CRC errato o OFF non canonico vengono scartati prima di applicare qualunque modifica.
- Dopo un frame completo rifiutato è possibile ritentare nella stessa finestra. Dopo perdita/troncamento, lasciare almeno 400 ms senza simboli prima di reinviare il frame intero.
- Nessun ACK: il completamento dell'invio non prova la ricezione o l'applicazione fisica. Il CRC rileva corruzione, non autentica un'app locale.

## Frame v2 — stato completo

13 byte, 52 simboli, circa 4,16 secondi oltre alla baseline:

```
Offset  00 01 02 03 04 05 06   07 08 09 10    11    12
        4B 52 47 42 02 03 MODE  H  S  V SPEED CRC_H CRC_L
         K  R  G  B
```

`CMD=03` è l'unico comando v2. `MODE=0` spegne l'RGB e richiede `H=S=V=SPEED=0`. `MODE=1…22` imposta l'effetto e accende l'RGB; H, S, V e SPEED sono tutti byte 0–255. Il bridge scala V rispetto a `RGB_MATRIX_MAXIMUM_BRIGHTNESS` con `V * max / 255`, senza superare il limite della scheda. Usa l’API atomica `rgb_matrix_set_config_noeeprom()` aggiunta al sorgente fissato. Questa protegge HSV e velocità dalla rilettura EEPROM per tutti i blocchi del primo frame e termina la protezione nel flush. Abilita RGB prima di impostare modo e HSV: nel ramo Keychron i setter ignorano il comando mentre RGB è spento e l’abilitazione rialza temporaneamente la luminosità minima; impostare HSV dopo conserva l’intero intervallo richiesto, incluso zero. Tonalità e saturazione vengono accettate anche dagli effetti che non le usano visivamente. SPEED viene impostata anche per il colore statico, dove non produce animazione. Il CRC copre i primi 11 byte.

I numeri di modalità sono ID stabili del protocollo. Il bridge li traduce **esplicitamente** in costanti QMK, senza affidarsi all'ordine dell'enum del firmware:

| MODE | Costante QMK |
| --- | --- |
| 0 | spegnimento tramite `rgb_matrix_disable_noeeprom()` |
| 1 | `RGB_MATRIX_SOLID_COLOR` |
| 2 | `RGB_MATRIX_BREATHING` |
| 3 | `RGB_MATRIX_BAND_SPIRAL_VAL` |
| 4 | `RGB_MATRIX_CYCLE_ALL` |
| 5 | `RGB_MATRIX_CYCLE_LEFT_RIGHT` |
| 6 | `RGB_MATRIX_CYCLE_UP_DOWN` |
| 7 | `RGB_MATRIX_RAINBOW_MOVING_CHEVRON` |
| 8 | `RGB_MATRIX_CYCLE_OUT_IN` |
| 9 | `RGB_MATRIX_CYCLE_OUT_IN_DUAL` |
| 10 | `RGB_MATRIX_CYCLE_PINWHEEL` |
| 11 | `RGB_MATRIX_CYCLE_SPIRAL` |
| 12 | `RGB_MATRIX_DUAL_BEACON` |
| 13 | `RGB_MATRIX_RAINBOW_BEACON` |
| 14 | `RGB_MATRIX_JELLYBEAN_RAINDROPS` |
| 15 | `RGB_MATRIX_PIXEL_RAIN` |
| 16 | `RGB_MATRIX_TYPING_HEATMAP` |
| 17 | `RGB_MATRIX_DIGITAL_RAIN` |
| 18 | `RGB_MATRIX_SOLID_REACTIVE_SIMPLE` |
| 19 | `RGB_MATRIX_SOLID_REACTIVE_MULTIWIDE` |
| 20 | `RGB_MATRIX_SOLID_REACTIVE_MULTINEXUS` |
| 21 | `RGB_MATRIX_SPLASH` |
| 22 | `RGB_MATRIX_SOLID_SPLASH` |

La lista corrisponde agli effetti abilitati nel `info.json` ufficiale della Q6 Max. RGB per singolo tasto e Mix RGB (23/24 nell'app) non sono rappresentati da questo frame: vengono respinti, senza sostituirli silenziosamente con un altro effetto.

## Compatibilità v1

Il decoder continua ad accettare i frame precedenti di 11 byte:

```
4B 52 47 42 01 CMD H S V CRC_H CRC_L
```

`CMD=01` applica il colore statico, mantenendo la velocità corrente; `CMD=02` spegne e richiede H/S/V tutti zero. CRC sui primi nove byte, 44 simboli (~3,52 s). Versione e comando sono verificati separatamente: un CMD01 non è valido in un frame v2 e un CMD03 non è valido in v1.

## Vettori condivisi con Swift

Sono disponibili anche in [protocol-vectors.json](protocol-vectors.json). I CRC sono stati calcolati indipendentemente con Python `binascii.crc_hqx(payload, 0xffff)` e poi verificati nel test C.

```
v1 rosso:       4B 52 47 42 01 01 00 FF FF E3 C0
v1 HSV85/192/128:4B 52 47 42 01 01 55 C0 80 CC 2D
v1 spento:      4B 52 47 42 01 02 00 00 00 65 13
v2 rosso/127:   4B 52 47 42 02 03 01 00 FF FF 7F A2 1A
v2 nexus/200:   4B 52 47 42 02 03 14 55 C0 80 C8 6A A6
v2 spento:      4B 52 47 42 02 03 00 00 00 00 00 4B AF
v2 splash/255:  4B 52 47 42 02 03 16 FF FF FF FF 1B BF
```

## Integrazione QMK

Base esaminata: repository ufficiale `Keychron/qmk_firmware`, ramo `2025q3`, commit **`2b493ff95f2665db719b1e95c91babb5036e72f3`**, target **`keychron/q6_max/iso_encoder`**, keymap di partenza `keychron`.

1. Creare una keymap dedicata, conservando la configurazione esistente. Copiarvi `ble_rgb_protocol.c/.h`, `qmk_rgb_ble_bridge.c/.h` e `qmk_responsive_idle.c/.h`.
2. Aggiungere al suo `rules.mk`:

   ```make
   VIA_ENABLE = yes
   SRC += $(KEYMAP_PATH)/ble_rgb_protocol.c
   SRC += $(KEYMAP_PATH)/qmk_rgb_ble_bridge.c
   SRC += $(KEYMAP_PATH)/qmk_responsive_idle.c
   ```

3. Integrare i tre callback da `integration-hooks.example.c` negli hook già presenti, preservandone la logica. Non compilare l'esempio come seconda unità se definirebbe callback duplicati. Il componente di reattività definisce `q6_lpm_is_idle_user()`; la patch lo aggiunge come condizione all’hook Q6 originale `lpm_is_kb_idle()`, senza sostituirne i controlli. Non richiede un quarto callback nella keymap.
4. Non assegnare un keycode `RGB_BT_ARM` nella VIA EEPROM: il v2 usa la posizione fisica Fn + tasto grafico. La mappa utente salvata non deve essere resettata per attivare la combinazione.
5. Eseguire `python3 firmware/apply-qmk-patch.py PERCORSO_QMK`. Lo script verifica il commit e aggiunge un hook di filtraggio della maschera LED ai due renderer originali, quello generico e quello RGB personalizzato; estende inoltre `rgb_matrix.c/.h` con l’API atomica per lo stato volatile e la protezione fino al primo flush. Estende `q6_max.c` con il veto weak `q6_lpm_is_idle_user()` nella condizione idle originale. Aggiunge inoltre i getter di sola lettura `wireless_get_connected_idle_timeout()` e `battery_has_valid_reading()` nei sorgenti/header wireless/battery. Il secondo conserva solo un flag RAM, azzerato da `battery_init()` e valorizzato da `battery_set_voltage()` per letture plausibili da 1 a `FULL_VOLTAGE_VALUE + 300` mV (4400 nel target). È idempotente; `--check` valida senza scrivere. Aggiunge inoltre `rgb_matrix_save_lighting()` e `rgb_save_retail_demo_if_changed()` per le scritture RGB mirate di v3. Non opera sull’hardware.
6. Compilare per ISO con tutte le dipendenze fissate al commit. Verificare dimensione del binario, risoluzione degli hook ed eventuali warning.
7. Prima di un eventuale primo flash via USB, conservare export VIA/macros e firmware ufficiale ISO per il ripristino. Il flash resta un'operazione separata da questi sorgenti. Il modulo radio non viene modificato.

`keychron_filter_os_indicator_state()` filtra soltanto i due bit Caps/Num per gli overlay della Q6 Max ISO (LED 62/37). Durante l’armamento legacy mantiene lo stato precedente dei due indicatori; lo conserva anche per 600 ms dopo ricezione/cancel/timeout, affinché l'ultimo simbolo CRC non appaia prima del ripristino del mittente. Il resto della matrice continua il proprio effetto. Lo stato effettivo di Caps Lock/Num Lock del Mac non viene alterato.

Lo script di integrazione lascia entrambi i renderer `os_state_indicate()` originali: quello weak in `backlit_indicator.c` e quello forte in `rgb/keychron_rgb.c`, effettivamente usato dalla keymap Keychron. I colori personalizzati, i flag di disabilitazione, gli altri bit LED e la sospensione USB restano gestiti dal codice originale. Gli indicatori di connessione, batteria e factory status sono chiamate separate in `keychron_task.c`, che il bridge lascia intatte. Le guardie di compilazione limitano il bridge alla variante ISO con LED Caps/Num 62/37.

## Verifiche locali

```sh
zsh scripts/setup-firmware.sh --source-only
sh firmware/test.sh
```

Il comando compila cinque eseguibili temporanei con `-Wall -Wextra -Werror -pedantic -fsanitize=address,undefined`, esegue i test e rimuove gli eseguibili:

- Decoder portabile: v3 automatico preview/save, ripetizione, 208 corruzioni aggiuntive, troncamenti, comandi e modi non validi, rumore e rollover; v1 compatibile; vettori v2; 256 maschere LED iniziali; 22 modalità × 256 valori speed/HSV; callback duplicati; one-shot e riarmamento; 192 corruzioni di singolo bit; modalità 23–255 e frame semanticamente invalidi con CRC corretto; tutti i punti di troncamento e perdita di simbolo; magic nel payload; recovery, rumore, timeout, scadenza assoluta e rollover.
- Bridge con API QMK simulate: combinazione fisica breve/lunga, ordine dei tasti, annullamento, scadenza senza riarmo, cambio trasporto; traduzione esplicita di tutti gli effetti; abilitazione prima dei setter, scala luminosità completa, velocità, OFF e v1; stop demo in RAM sui comandi legacy/preview; nessuna applicazione v1/v2 senza armamento; v3 diretto, persistenza soltanto per comando 4, accodamento fuori dal callback e annullamento con USB/disconnessione; filtro Caps/Num con tutti i 256 stati LED e passaggio invariato USB. I contatori dei mock distinguono anteprima e richiesta di salvataggio.

- Transizione del renderer: estrae in memoria dal sorgente QMK le funzioni effettive modificate e le compila contro una EEPROM simulata. Verifica protezione HSV/velocità in tutti i blocchi del primo frame, modalità invariata, OFF→ON, valori estremi, effetto manuale successivo o durante un frame, nuovo stato prima del flush, patch idempotente e zero scritture per i percorsi temporanei. Per v3 compila il vero helper di salvataggio e verifica riavvio simulato verde Respiro/OFF/valori zero, conservazione di flag/byte riservati, scritture identiche eliminate e salvataggio del solo byte demo. Richiede il checkout fissato in `build/qmk-firmware`.

- Politica di sospensione: 304.128 combinazioni di trasporto, stato wireless, timeout, tensione, flag batteria e guardie degli indicatori Q6; inclusi limite 3500 mV, valori adiacenti al preset, dati iniziali mancanti, valori impossibili, risveglio/inizializzazione e cambio immediato del timeout. Collega il corpo reale dell’hook Q6 e il suo default weak con il nostro veto forte, insieme alle funzioni reali batteria estratte dal sorgente dopo la patch; le altre API sono simulate.

- Decoder 0.5 congelato: copia SHA256 verificata del decoder usato nella build precedente; respinge tutte le combinazioni di comandi e modalità v3 anche dopo armamento.

Questi test non inviano report HID, non aprono la tastiera e non effettuano flash.

## Evidenze e limiti

**Osservato nel sorgente ufficiale:** gli eventi `LKBT51_EVT_HID_EVENT` aggiornano `led_state`; la Q6 abilita gli effetti elencati; i renderer `os_state_indicate()` sono separati dagli indicatori wireless, con un’implementazione weak generica e una forte per RGB personalizzato; esistono le API RGB `_noeeprom`. Le coordinate del gate provengono dal layout ISO ufficiale.

**Scelta progettuale/inferenza:** usare Num/Caps/Scroll come due bit dati + clock e decodificarli nel firmware personalizzato. Il CRC evita applicazioni parziali o corrotte; non recupera eventi persi e non garantisce consegna.

**Osservato sull’hardware il 26 ottobre 2026:** la prima build richiedeva due invii per ottenere verde fisso; la correzione 0.5 installata ha poi prodotto verde Respiro al primo invio con USB scollegata, digitazione normale e profilo ripristinato. Successivamente la 0.6 ha ricevuto verde Respiro senza fn + ○ e lo ha conservato dopo un ciclo di alimentazione reale, confermato con USB scollegata e digitazione normale. Gli altri effetti e OFF persistente non sono stati collaudati tutti singolarmente sull’unità.

Revisione dei callback, degli effetti e della EEPROM: [INTEGRATION_REVIEW.md](INTEGRATION_REVIEW.md). Sorgenti primari: [Q6 Max info.json al commit fissato](https://github.com/Keychron/qmk_firmware/blob/2b493ff95f2665db719b1e95c91babb5036e72f3/keyboards/keychron/q6_max/info.json), [layout ISO](https://github.com/Keychron/qmk_firmware/blob/2b493ff95f2665db719b1e95c91babb5036e72f3/keyboards/keychron/q6_max/iso_encoder/keyboard.json), [indicatori Keychron](https://github.com/Keychron/qmk_firmware/blob/2b493ff95f2665db719b1e95c91babb5036e72f3/keyboards/keychron/common/backlit_indicator.c).
