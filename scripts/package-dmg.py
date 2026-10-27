#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Create a portable drag-to-Applications DMG from the verified app only.

Run with build/packaging-venv/bin/python after installing packaging-requirements.txt.
No personal state, research, owner keys, or development apps enter the image.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from ds_store import DSStore

ROOT=Path(__file__).resolve().parent.parent
bundle=ROOT/'dist/Keyglow.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)
info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
version=info['CFBundleShortVersionString']
output=ROOT/f'dist/Keyglow-{version}-macOS-arm64.dmg'
with tempfile.TemporaryDirectory(prefix='keyglow-dmg-',dir=ROOT/'build') as temporary:
    stage=Path(temporary)/'contents';stage.mkdir()
    subprocess.run(['ditto','--norsrc','--noextattr',str(bundle),str(stage/'Keyglow.app')],check=True)
    os.symlink('/Applications',stage/'Applications')
    (stage/'Inizia qui.txt').write_text(f'''Keyglow {version} · Mac con Apple Silicon · macOS 13 o successivo

Trascina Keyglow in Applications, poi aprila da Applicazioni ed espelli questo disco.
Al primo avvio l’app guida nel modello, nei permessi e nella scelta del firmware.
La prima installazione della Q6 Max ISO richiede USB: backup, DFU, conferma dei file,
installazione verificata e ripristino sono nella pagina Firmware.

Questa versione è sperimentale, firmata localmente e non notarizzata da Apple.
Il nuovo percorso USB integrato è verificato con test software, ma non ancora
provato fisicamente dall’inizio alla fine. Una prima scrittura del loader interrotta
può richiedere recupero hardware. Leggi il riepilogo nell’app prima di confermare.
Durante un aggiornamento Bluetooth usa solo il mouse: tasti e manopola interrompono
il trasferimento. I blocchi già verificati possono essere ripresi.

Se macOS blocca l’apertura, consulta Privacy e sicurezza nelle Impostazioni di Sistema
solo dopo aver verificato che il file provenga dalla release ufficiale del progetto.
Keyglow richiede Monitoraggio input per il collegamento HID; il consenso resta tuo.
La firma locale non è una firma Developer ID riconosciuta sui Mac di altre persone.

Profili, backup e chiavi rimangono sul Mac: non si trovano dentro questo DMG.
Puoi spostare l’intera app senza spostare i suoi dati.
Sorgenti: https://github.com/FrancoisLampasona/keyglow-macos
Licenza GPL-2.0-or-later. Progetto indipendente, non affiliato a Keychron.
''')
    with DSStore.open(str(stage/'.DS_Store'),'w+') as store:
        store['.']['bwsp']={'ShowToolbar':False,'ShowStatusBar':False,'ShowSidebar':False,'ShowPathbar':False,'ShowTabView':False,'WindowBounds':'{{200, 160}, {660, 420}}'}
        store['.']['icvp']={'viewOptionsVersion':1,'backgroundType':0,'iconSize':88.0,'textSize':13.0,'gridSpacing':100.0,'gridOffsetX':0.0,'gridOffsetY':0.0,'arrangeBy':'none','labelOnBottom':True,'showIconPreview':True,'showItemInfo':False}
        store['.']['vSrn']=('long',1)
        store['.']['vstl']=('type',b'icnv')
        store['Keyglow.app']['Iloc']=(170,140)
        store['Applications']['Iloc']=(490,140)
        store['Inizia qui.txt']['Iloc']=(330,300)
    subprocess.run(['hdiutil','create','-volname','Keyglow '+version,'-srcfolder',str(stage),'-format','UDZO','-imagekey','zlib-level=9','-ov',str(output)],check=True)
subprocess.run(['hdiutil','verify',str(output)],check=True)
checksum=hashlib.sha256(output.read_bytes()).hexdigest()
Path(str(output)+'.sha256').write_text(checksum+'  '+output.name+'\n')
print(output)
print('SHA256 '+checksum)
