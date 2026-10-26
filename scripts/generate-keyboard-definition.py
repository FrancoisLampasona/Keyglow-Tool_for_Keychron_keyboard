#!/usr/bin/env python3
"""Regenerate the Q6 Max ISO model from pinned, official Keychron sources.

Default uses the source keycode map retained in q6-max-iso.json. Pass --refresh
(and optionally --keycodes-header PATH) to rebuild that map from pinned QMK.
The physical legends/colors are the user's Italian reference, not live settings.
"""
from pathlib import Path
import argparse, hashlib, json, re, urllib.request
ROOT = Path(__file__).resolve().parents[1]
COMMIT = '2b493ff95f2665db719b1e95c91babb5036e72f3'
UPSTREAM = f'https://raw.githubusercontent.com/Keychron/qmk_firmware/{COMMIT}/'
RESOURCE = ROOT / 'macOS/Resources/q6-max-iso.json'
parser = argparse.ArgumentParser()
parser.add_argument('--qmk-root', type=Path, default=ROOT / 'build/qmk-firmware')
parser.add_argument('--refresh', action='store_true')
parser.add_argument('--keycodes-header', type=Path)
args = parser.parse_args()
QMK_ROOT = args.qmk_root.resolve()
BASE = QMK_ROOT / 'keyboards/keychron'
Q6 = BASE / 'q6_max'

def sha(data): return hashlib.sha256(data).hexdigest()
def read(relative): return (ROOT/relative).read_text()
def source_record(path):
    p=Path(path); rel=p.relative_to(QMK_ROOT)
    return {'path':str(rel),'url':UPSTREAM+rel.as_posix(),'sha256':sha(p.read_bytes())}

via=json.loads((Q6/'via_json/q6_max_iso_encoder.json').read_text())
keyboard=json.loads((Q6/'iso_encoder/keyboard.json').read_text())
keymap=(Q6/'iso_encoder/keymaps/keychron/keymap.c').read_text()
led_source=(Q6/'iso_encoder/iso_encoder.c').read_text()
if RESOURCE.exists() and not args.refresh and not args.keycodes_header:
    prior=json.loads(RESOURCE.read_text()); codes=prior['sourceKeycodes']; header_hash=prior['provenance']['keycodesSHA256']
else:
    raw=args.keycodes_header.read_bytes() if args.keycodes_header else urllib.request.urlopen(UPSTREAM+'quantum/keycodes.h',timeout=20).read()
    header=raw.decode(); header_hash=sha(raw)
    codes={name:int(value,16) for name,value in re.findall(r'^\s*(\w+)\s*=\s*(0x[0-9A-Fa-f]+)\s*,',header,re.M)}
    aliases=re.findall(r'^\s*(\w+)\s*=\s*(\w+)\s*,',header,re.M)
    for _ in range(5):
        for name,other in aliases:
            if other in codes: codes[name]=codes[other]
# Keychron Q6 Max flags: no WIN/MAC_LOCK_SCREEN or connection-toggle flag.
custom=[('KC_LOPTN','Option sinistro','L⌥'),('KC_ROPTN','Option destro','R⌥'),('KC_LCMMD','Command sinistro','L⌘'),('KC_RCMMD','Command destro','R⌘'),('KC_MCTRL','Mission Control','Mission'),('KC_LNPAD','Launchpad','Launchpad'),('KC_TASK','Vista attività Windows','Task'),('KC_FILE','Esplora file Windows','Explorer'),('KC_SNAP','Screenshot macOS','Screenshot'),('KC_CTANA','Cortana','Cortana'),('KC_SIRI','Siri','Siri'),('BT_HST1','Bluetooth dispositivo 1','BT 1'),('BT_HST2','Bluetooth dispositivo 2','BT 2'),('BT_HST3','Bluetooth dispositivo 3','BT 3'),('P2P4G','Connessione 2,4 GHz','2,4 GHz'),('BAT_LVL','Mostra batteria','Batteria')]
for i,(name,_,_) in enumerate(custom): codes[name]=codes['QK_KB_0']+i
codes.update({'_______':codes['KC_TRANSPARENT'],'FN_MAC':codes['QK_MOMENTARY']|1,'FN_WIN':codes['QK_MOMENTARY']|3})

# KLE has the secondary rectangle of the ISO Enter, absent from keyboard.json.
kle={}; y=0.0
for row in via['layouts']['keymap']:
    x=0.0; props={}
    for entry in row:
        if isinstance(entry,dict):
            x+=entry.get('x',0); y+=entry.get('y',0)
            props.update({k:v for k,v in entry.items() if k not in ['x','y','c']})
        else:
            matrix=entry.split('\n')[0]; record={'x':x,'y':y,'width':props.get('w',1),'height':props.get('h',1)}
            if any(k in props for k in ['x2','y2','w2','h2']):
                record['secondary']={'x':props.get('x2',0),'y':props.get('y2',0),'width':props.get('w2',record['width']),'height':props.get('h2',record['height'])}
            kle[matrix]=record; x+=record['width']; props={}
    y+=1
layout=keyboard['layouts']['LAYOUT_iso_110']['layout']
assert len(layout)==len(kle)==110
assert len({tuple(k['matrix']) for k in layout})==110
# All KLE geometry is checked against the firmware layout, not inferred by row.
for key in layout:
    r,c=key['matrix']; official=kle[f'{r},{c}']
    for dst,src,default in [('x','x',0),('y','y',0),('width','w',1),('height','h',1)]:
        assert official[dst]==key.get(src,default),(r,c,dst,official[dst],key.get(src,default))
led_rows=re.search(r'// Key Matrix to LED Index(.*?)\n\s*\},',led_source,re.S).group(1)
led_matrix=[]
for row in re.findall(r'\{([^}]+)\}',led_rows):
    led_matrix.append([None if t.strip()=='__' else int(t.strip()) for t in row.split(',') if t.strip()])
assert len(led_matrix)==6 and all(len(r)==20 for r in led_matrix)
assert sorted(v for r in led_matrix for v in r if v is not None)==list(range(109))

# Physical legends: Italian keycaps and Mac caps shown in the user's photograph.
legends={}
def setrow(r,values):
    for c,main,secondary in values:legends[(r,c)]=(main,secondary)
setrow(0,[(0,'esc','')]+[(i,f'F{i}','') for i in range(1,13)]+[(13,'',''),(14,'',''),(15,'',''),(16,'',''),(17,'○',''),(18,'△',''),(19,'□','')])
legends[(3,13)]=('×','')
setrow(1,[(0,'\\','|'),(1,'1','!'),(2,'2','"'),(3,'3','£'),(4,'4','$'),(5,'5','%'),(6,'6','&'),(7,'7','/'),(8,'8','('),(9,'9',')'),(10,'0','='),(11,"'",'?'),(12,'ì','^'),(13,'← backspace',''),(14,'ins',''),(15,'home',''),(16,'pgup',''),(17,'num clear',''),(18,'/',''),(19,'*','')])
legends[(3,14)]=('−','')
setrow(2,[(0,'tab ⇥','')]+[(i,c,'') for i,c in enumerate('QWERTYUIOP',1)]+[(11,'è','é  [  {'),(12,'+','*  ]  }'),(13,'↵ enter',''),(14,'del',''),(15,'end',''),(16,'pgdn',''),(17,'7',''),(18,'8',''),(19,'9','')])
setrow(3,[(0,'caps lock','')]+[(i,c,'') for i,c in enumerate('ASDFGHJKL',1)]+[(10,'ò','ç  @'),(11,'à','°  #'),(12,'ù','§'),(15,'+',''),(16,'enter',''),(17,'4',''),(18,'5',''),(19,'6','')])
setrow(4,[(0,'⇧ shift',''),(1,'<','>')]+[(i,c,'') for i,c in enumerate('ZXCVBNM',2)]+[(9,',',';'),(10,'.',':'),(11,'-','_'),(13,'⇧ shift',''),(15,'↑',''),(17,'1',''),(18,'2',''),(19,'3','')])
setrow(5,[(0,'control',''),(1,'option',''),(2,'⌘',''),(6,'',''),(10,'⌘',''),(11,'option',''),(12,'fn',''),(13,'control',''),(14,'←',''),(15,'↓',''),(16,'→',''),(18,'0',''),(19,'.','')])
symbols={(0,1):'sun.min',(0,2):'sun.max',(0,3):'rectangle.3.group',(0,4):'square.grid.3x3',(0,5):'sun.min',(0,6):'sun.max',(0,7):'backward.end',(0,8):'playpause',(0,9):'forward.end',(0,10):'speaker.slash',(0,11):'speaker.wave.1',(0,12):'speaker.wave.3',(0,14):'viewfinder',(0,15):'mic',(0,16):'lightbulb'}
keys=[]
for k in layout:
    r,c=k['matrix']; item=dict(kle[f'{r},{c}'])
    appearance='light'
    if (r,c)==(0,0):appearance='accent'
    elif (r,c)==(0,13):appearance='knob'
    elif r==0 and (5<=c<=8 or 14<=c<=16):appearance='dark'
    elif r in [1,2] and 13<=c<=16:appearance='dark'
    elif r in [2,3] and c==0:appearance='dark'
    elif (r,c) in [(4,0),(4,13)]:appearance='dark'
    elif r==5 and c in [0,1,2,10,11,12,13]:appearance='dark'
    main,secondary=legends[(r,c)]
    item.update(id=f'{r},{c}',row=r,col=c,legend=main,secondaryLegend=secondary,appearance=appearance,isEncoder=(r,c)==(0,13),ledIndex=led_matrix[r][c],symbolName=symbols.get((r,c)))
    keys.append(item)
# Layout macro argument order must follow keyboard.json, not KLE display order.
layer_names=['MAC_BASE','MAC_FN','WIN_BASE','WIN_FN']; default_layers=[]; default_symbols=[]
for name in layer_names:
    content=re.search(r'\['+name+r'\]\s*=\s*LAYOUT_iso_110\((.*?)\)',keymap,re.S).group(1)
    tokens=[t.strip() for t in content.split(',') if t.strip()]
    assert len(tokens)==len(layout),(name,len(tokens))
    matrix=[0]*120; symbol_matrix=['KC_NO']*120
    for key,token in zip(layout,tokens):
        r,c=key['matrix'];matrix[r*20+c]=codes[token];symbol_matrix[r*20+c]=token
    default_layers.append(matrix);default_symbols.append(symbol_matrix)
default_encoders=[]
for name in layer_names:
    ccw,cw=re.search(r'\['+name+r'\]\s*=\s*\{ENCODER_CCW_CW\((\w+),\s*(\w+)\)',keymap).groups()
    default_encoders.append([codes[ccw],codes[cw]])

# Readable catalog. Basic USB keyboard, modifiers/media and mouse codes are
# canonical QMK entries; lighting entries match this build's UG aliases.
entries={}
def add(symbol,name,short,category):
    code=codes[symbol];entries[code]={'code':code,'name':name,'shortName':short,'category':category,'symbol':symbol}
for symbol,code in codes.items():
    if symbol.startswith('KC_') and code<=0xFF and not symbol.endswith('_MAX'):
        # Prefer descriptive names; aliases are replaced explicitly below.
        if code not in entries:
            words=symbol.removeprefix('KC_').replace('_',' ').title()
            category='Lettere e simboli'
            if 0x3A<=code<=0x73:category='Funzione e navigazione'
            if 0xA5<=code<0xE0:category='Multimedia e sistema'
            if code>=0xE0:category='Modificatori'
            add(symbol,words,words if len(words)<9 else symbol.removeprefix('KC_'),'category')
            entries[code]['category']=category
for key in keys:
    code=default_layers[0][key['row']*20+key['col']]
    if code<0xA5 and code in entries and key['legend']:
        entries[code]['shortName']=key['legend']
        if 4<=code<=29:entries[code]['name']=key['legend']
for symbol,name,short in [('KC_NO','Nessuna azione','Nessuno'),('KC_TRANSPARENT','Trasparente: usa livello inferiore','▽'),('KC_ENT','Invio','Invio'),('KC_ESC','Escape','Esc'),('KC_BSPC','Cancella indietro','⌫'),('KC_TAB','Tabulazione','⇥'),('KC_SPC','Spazio','Spazio'),('KC_CAPS','Blocco maiuscole','Caps'),('KC_INS','Inserisci','Ins'),('KC_DEL','Cancella avanti','Del'),('KC_HOME','Inizio','Home'),('KC_END','Fine','End'),('KC_PGUP','Pagina su','PgUp'),('KC_PGDN','Pagina giù','PgDn'),('KC_LEFT','Freccia sinistra','←'),('KC_RGHT','Freccia destra','→'),('KC_UP','Freccia su','↑'),('KC_DOWN','Freccia giù','↓')]:
    add(symbol,name,short,'Base')
for symbol,name,short in [('KC_LCTL','Control sinistro','L Ctrl'),('KC_RCTL','Control destro','R Ctrl'),('KC_LSFT','Shift sinistro','L ⇧'),('KC_RSFT','Shift destro','R ⇧'),('KC_LALT','Alt / Option sinistro','L Alt'),('KC_RALT','Alt / Option destro','R Alt'),('KC_LGUI','GUI / Command sinistro','L ⌘'),('KC_RGUI','GUI / Command destro','R ⌘')]:add(symbol,name,short,'Modificatori')
for symbol,name,short in [('KC_MUTE','Disattiva audio','Mute'),('KC_VOLU','Aumenta volume','Vol +'),('KC_VOLD','Riduci volume','Vol −'),('KC_MPRV','Traccia precedente','Precedente'),('KC_MNXT','Traccia successiva','Successiva'),('KC_MPLY','Riproduci / pausa','Play/Pausa'),('KC_BRID','Riduci luminosità schermo','Schermo −'),('KC_BRIU','Aumenta luminosità schermo','Schermo +')]:add(symbol,name,short,'Multimedia e sistema')
for symbol,name,short in custom:add(symbol,name,short,'Keychron')
for symbol,name,short in [('UG_TOGG','Accendi / spegni RGB','RGB On/Off'),('UG_NEXT','Effetto RGB successivo','Effetto +'),('UG_PREV','Effetto RGB precedente','Effetto −'),('UG_HUEU','Tonalità RGB +','Hue +'),('UG_HUED','Tonalità RGB −','Hue −'),('UG_SATU','Saturazione RGB +','Sat +'),('UG_SATD','Saturazione RGB −','Sat −'),('UG_VALU','Luminosità RGB +','RGB +'),('UG_VALD','Luminosità RGB −','RGB −'),('UG_SPDU','Velocità RGB +','Velocità +'),('UG_SPDD','Velocità RGB −','Velocità −')]:add(symbol,name,short,'Illuminazione')
for n in range(1,25):
    symbol=f'KC_F{n}';add(symbol,f'Funzione F{n}',f'F{n}','Funzione e navigazione')
for layer in range(4):
    for op,base,title in [('MO','QK_MOMENTARY','Livello temporaneo'),('TG','QK_TOGGLE_LAYER','Attiva / disattiva livello'),('TO','QK_TO','Passa al livello'),('DF','QK_DEF_LAYER','Livello predefinito')]:
        value=codes[base]|layer;entries[value]={'code':value,'name':f'{title} {layer}','shortName':f'{op}({layer})','category':'Livelli','symbol':f'{op}({layer})'}
for macro in range(16):add(f'QK_MACRO_{macro}',f'Macro {macro}',f'M{macro}','Macro')
entries=sorted(entries.values(),key=lambda e:(e['category'],e['code']))
# All defaults resolve to a catalog entry; alias labels remain source data.
assert set(v for layer in default_layers for v in layer)<=set(e['code'] for e in entries)
resource={'schemaVersion':1,'name':'Keychron Q6 Max ISO · Italiano','vendorID':0x3434,'productID':0x0861,'rows':6,'columns':20,'width':22.5,'height':6.25,'keys':keys,'layerNames':['Mac','Mac Fn','Windows','Windows Fn'],'defaultLayers':default_layers,'defaultSymbols':default_symbols,'defaultEncoders':default_encoders,'keycodes':entries,'sourceKeycodes':codes,'officialVIA':via,'officialKeyboard':keyboard,'provenance':{'commit':COMMIT,'repository':'https://github.com/Keychron/qmk_firmware','sources':[source_record(p) for p in [Q6/'via_json/q6_max_iso_encoder.json',Q6/'iso_encoder/keyboard.json',Q6/'iso_encoder/keymaps/keychron/keymap.c',Q6/'iso_encoder/iso_encoder.c',BASE/'common/keychron_common.h']],'keycodesURL':UPSTREAM+'quantum/keycodes.h','keycodesSHA256':header_hash,'physicalReference':'Italian ISO reference: black case, Italian keycaps, white/light gray alphas and keypad, dark modifiers, teal Esc. Legends are physical labels; source defaults are not a device read.'}}
RESOURCE.write_text(json.dumps(resource,ensure_ascii=False,indent=2)+'\n')

def s(value):return json.dumps(value,ensure_ascii=False)
def f(value):return repr(float(value))
lines=['// Generated by scripts/generate-keyboard-definition.py. Do not hand-edit arrays.', '// Official source commit '+COMMIT+'. Keychron/QMK data: GPL-2.0-or-later.', 'import Foundation', '', '''struct KeyRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum KeyAppearance: String, Codable, Sendable { case light, dark, accent, knob }

struct PhysicalKey: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let row: Int
    let col: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// Relative to the primary rectangle origin (ISO Enter's upper extension).
    let secondary: KeyRect?
    let legend: String
    let secondaryLegend: String
    let appearance: KeyAppearance
    let isEncoder: Bool
    let ledIndex: Int?
    let symbolName: String?
    var matrixIndex: Int { row * 20 + col }
}

struct KeyboardDefinition: Sendable {
    let name: String
    let vendorID: Int
    let productID: Int
    let rows: Int
    let columns: Int
    let width: Double
    let height: Double
    let keys: [PhysicalKey]
    let layerNames: [String]
    /// Pinned upstream factory defaults, never presented as live device state.
    let defaultLayers: [[UInt16]]
    /// Per layer: [counterclockwise, clockwise].
    let defaultEncoders: [[UInt16]]
    func key(row: Int, col: Int) -> PhysicalKey? { keys.first { $0.row == row && $0.col == col } }
    func key(id: String) -> PhysicalKey? { keys.first { $0.id == id } }
    static let q6ISO = KeyboardDefinition(name: "Keychron Q6 Max ISO · Italiano", vendorID: 0x3434, productID: 0x0861, rows: 6, columns: 20, width: 22.5, height: 6.25, keys: physicalKeys, layerNames: ["Mac", "Mac Fn", "Windows", "Windows Fn"], defaultLayers: factoryLayers, defaultEncoders: factoryEncoders)
    private static let physicalKeys: [PhysicalKey] = [''']
for key in keys:
    rect=key.get('secondary');secondary='nil' if not rect else 'KeyRect('+', '.join(k+': '+f(rect[k]) for k in ['x','y','width','height'])+')'
    fields=['id: '+s(key['id']),'row: '+str(key['row']),'col: '+str(key['col'])]+[k+': '+f(key[k]) for k in ['x','y','width','height']]+['secondary: '+secondary,'legend: '+s(key['legend']),'secondaryLegend: '+s(key['secondaryLegend']),'appearance: .'+key['appearance'],'isEncoder: '+str(key['isEncoder']).lower(),'ledIndex: '+('nil' if key['ledIndex'] is None else str(key['ledIndex'])),'symbolName: '+('nil' if key['symbolName'] is None else s(key['symbolName']))]
    lines.append('        PhysicalKey('+', '.join(fields)+'),')
lines+=['    ]','    private static let factoryLayers: [[UInt16]] = [']
for layer in default_layers:lines.append('        ['+', '.join('0x%04X'%v for v in layer)+'],')
lines+=['    ]','    private static let factoryEncoders: [[UInt16]] = [']
for enc in default_encoders:lines.append('        ['+', '.join('0x%04X'%v for v in enc)+'],')
lines+=['    ]','}', '', '''struct KeycodeInfo: Identifiable, Hashable, Sendable {
    let code: UInt16
    let name: String
    let shortName: String
    let category: String
    var id: UInt16 { code }
}

enum KeycodeCatalog {
    static let entries: [KeycodeInfo] = [''']
for entry in entries:lines.append('        KeycodeInfo(code: 0x%04X, name: %s, shortName: %s, category: %s),'%(entry['code'],s(entry['name']),s(entry['shortName']),s(entry['category'])))
lines+=['''    ]
    static let categories = Array(Set(entries.map(\\.category))).sorted()
    private static let byCode = Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0) })
    static func info(_ code: UInt16) -> KeycodeInfo? { byCode[code] }
    static func display(_ code: UInt16) -> String { byCode[code]?.shortName ?? String(format: "0x%04X", code) }
    static func search(_ query: String) -> [KeycodeInfo] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.shortName.localizedCaseInsensitiveContains(text) || $0.category.localizedCaseInsensitiveContains(text) || String(format: "0x%04X", $0.code).localizedCaseInsensitiveContains(text) }
    }
}
''']
(ROOT/'macOS/Sources/KeyboardDefinition.swift').write_text('\n'.join(lines))
print(f'Generated {len(keys)} physical positions, 109 unique LEDs, 4 x 120 matrix values, {len(entries)} catalog actions.')
