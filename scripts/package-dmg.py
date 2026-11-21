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
try:
    from ds_store import DSStore
except ImportError:
    # Only the Finder window layout needs it; the image itself does not.
    DSStore=None

ROOT=Path(__file__).resolve().parent.parent
bundle=ROOT/'dist/Keyglow.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)
info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
version=info['CFBundleShortVersionString']
# Set by scripts/sign-app.py: developerCertificate, localCertificate or adhoc.
developer_id=info.get('KeyglowSigningMode')=='developerCertificate'
signing_it=('Questa versione è sperimentale. L’app è firmata con un certificato Developer ID Apple;\nle note della release indicano se questa immagine è anche notarizzata da Apple.' if developer_id else
            'Questa versione è sperimentale, firmata localmente e non notarizzata da Apple.')
signing_en=('This experimental app is signed with an Apple Developer ID certificate; the release\nnotes say whether this image is also notarized by Apple. Review the official release before' if developer_id else
            'This experimental app is locally signed, not Apple-notarized; the local certificate\nis not a trusted Developer ID on other Macs. Review the official release before')
signing_fr=('Cette app expérimentale est signée avec un certificat Developer ID Apple ; les notes de\nversion indiquent si cette image est aussi notarisée par Apple. Vérifiez la version officielle' if developer_id else
            'Cette app expérimentale est signée localement, sans notarisation Apple ; le certificat\nlocal n’est pas un Developer ID reconnu sur les autres Mac. Vérifiez la version officielle')
local_note_it='' if developer_id else 'La firma locale non è una firma Developer ID riconosciuta sui Mac di altre persone.\n'

output=ROOT/f'dist/Keyglow-{version}-macOS-arm64.dmg'
with tempfile.TemporaryDirectory(prefix='keyglow-dmg-',dir=ROOT/'build') as temporary:
    stage=Path(temporary)/'contents';stage.mkdir()
    subprocess.run(['ditto','--norsrc','--noextattr',str(bundle),str(stage/'Keyglow.app')],check=True)
    os.symlink('/Applications',stage/'Applications')
    (stage/'Read Me - Leggimi - Lisez-moi.txt').write_text(f'''Keyglow {version} · Mac con Apple Silicon · macOS 13 o successivo

Trascina Keyglow in Applications, poi aprila da Applicazioni ed espelli questo disco.
Al primo avvio l’app guida nel modello, nei permessi e nella scelta del firmware.
La prima installazione della Q6 Max ISO richiede USB: backup, DFU, conferma dei file,
installazione verificata e ripristino sono nella pagina Firmware.

{signing_it}
Il nuovo percorso USB integrato è verificato con test software, ma non ancora
provato fisicamente dall’inizio alla fine. Una prima scrittura del loader interrotta
può richiedere recupero hardware. Leggi il riepilogo nell’app prima di confermare.
Durante un aggiornamento Bluetooth usa solo il mouse: tasti e manopola interrompono
il trasferimento. I blocchi già verificati possono essere ripresi.

Se macOS blocca l’apertura, consulta Privacy e sicurezza nelle Impostazioni di Sistema
solo dopo aver verificato che il file provenga dalla release ufficiale del progetto.
Keyglow richiede Monitoraggio input per il collegamento HID; il consenso resta tuo.
{local_note_it}
Profili, backup e chiavi rimangono sul Mac: non si trovano dentro questo DMG.
Puoi spostare l’intera app senza spostare i suoi dati.
Sorgenti: https://github.com/FrancoisLampasona/Keyglow-Tool_for_Keychron_keyboard
Licenza GPL-2.0-or-later. Progetto indipendente, non affiliato a Keychron.


ENGLISH
Drag Keyglow into Applications, open it there, then eject this disk.
Choose English in the globe menu during setup or in the sidebar footer.
The assistant checks the model, macOS permissions and firmware requirements.
Initial firmware installation requires USB/DFU; backup and restore are guided
inside the app. The integrated first-install path has not yet been physically
validated end to end. Keep power connected during the initial loader write.
{signing_en}
using macOS per-app approval. Do not disable system security globally.
Use only the mouse during Bluetooth firmware updates. Saved blocks can be resumed.
Your profiles, backups and keys stay on your Mac, outside this disk image.
Independent GPL-2.0-or-later project, not affiliated with Keychron.

FRANÇAIS
Glissez Keyglow dans Applications, ouvrez-la depuis ce dossier, puis éjectez ce disque.
Choisissez Français dans le menu globe de l’assistant ou au bas de la barre latérale.
L’assistant vérifie le modèle, les autorisations macOS et le firmware requis.
La première installation du firmware nécessite USB/DFU ; sauvegarde et restauration
sont guidées dans l’app. Ce parcours intégré n’a pas encore été validé physiquement
de bout en bout. Gardez l’alimentation connectée pendant l’écriture initiale du chargeur.
{signing_fr}
avant d’utiliser l’autorisation macOS par app. Ne désactivez pas la sécurité du système.
Utilisez uniquement la souris pendant les mises à jour Bluetooth. Les blocs enregistrés
peuvent être repris. Profils, sauvegardes et clés restent sur votre Mac, hors de ce disque.
Projet indépendant GPL-2.0-or-later, non affilié à Keychron.
''')
    if DSStore is None:
        print('ds_store not installed: default Finder layout (see scripts/packaging-requirements.txt)')
    else:
      with DSStore.open(str(stage/'.DS_Store'),'w+') as store:
          store['.']['bwsp']={'ShowToolbar':False,'ShowStatusBar':False,'ShowSidebar':False,'ShowPathbar':False,'ShowTabView':False,'WindowBounds':'{{200, 160}, {660, 420}}'}
          store['.']['icvp']={'viewOptionsVersion':1,'backgroundType':0,'iconSize':88.0,'textSize':13.0,'gridSpacing':100.0,'gridOffsetX':0.0,'gridOffsetY':0.0,'arrangeBy':'none','labelOnBottom':True,'showIconPreview':True,'showItemInfo':False}
          store['.']['vSrn']=('long',1)
          store['.']['vstl']=('type',b'icnv')
          store['Keyglow.app']['Iloc']=(170,140)
          store['Applications']['Iloc']=(490,140)
          store['Read Me - Leggimi - Lisez-moi.txt']['Iloc']=(330,300)
    subprocess.run(['hdiutil','create','-volname','Keyglow '+version,'-srcfolder',str(stage),'-format','UDZO','-imagekey','zlib-level=9','-ov',str(output)],check=True)
subprocess.run(['hdiutil','verify',str(output)],check=True)
# A Developer ID build also signs the image, which notarization requires.
identity=os.environ.get('SIGNING_IDENTITY')
if identity:
    subprocess.run(['codesign','--force','--timestamp','--sign',identity,str(output)],check=True)
    subprocess.run(['codesign','--verify','--strict',str(output)],check=True)
checksum=hashlib.sha256(output.read_bytes()).hexdigest()
Path(str(output)+'.sha256').write_text(checksum+'  '+output.name+'\n')
print(output)
print('SHA256 '+checksum)
