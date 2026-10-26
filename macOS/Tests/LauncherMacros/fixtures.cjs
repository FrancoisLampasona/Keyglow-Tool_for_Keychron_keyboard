// Produce expectations using ECMAScript itself, not the Swift implementation.
// Independent protocol-value fixture: no captured vendor JavaScript is needed.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const directory = process.argv[2];
const {codes} = require('./keycode-values.json');
const md5 = value => crypto.createHash('md5').update(value).digest('hex');
const make = (macro, name = macro.map((_, index) => 'Macro ' + (index + 1)), deviceID = 875825249) => ({md5:md5(JSON.stringify(macro) + deviceID), macro, name});
fs.mkdirSync(directory, {recursive:true});
const save = (name, value) => fs.writeFileSync(path.join(directory, name + '.json'), JSON.stringify(value, null, 2));
const macro = [
  [[2, 'Command ⌘\u2028\u2029\u000b', 'KC_LGUI'], [1, 'A" /\\\n', 'KC_A'], [4, 125], [3, 'Command', 'KC_LGUI'], [5, 'hello /"\\\b\f\n\r\t\u0002\u001f\u007f']],
  [],
  [[1, 'ISO', 'KC_NUHS']]
];
const names = ['Test è 🔊', 'Vuota', 'e\u0301'];
save('current', make(macro, names));
save('changed-names', make(macro, ['Renamed', '', 'Nomi non inclusi nel digest']));
save('legacy', macro);
const numeric = JSON.stringify(make(macro, names), null, 2).replace(/\b125(?=\s*[,\]])/g, '125.00e+0').replace(/(\[\s*)2(?=,)/, '$12.0').replaceAll('Command', '\\u0043ommand');
fs.writeFileSync(path.join(directory, 'numeric-escaped.json'), numeric);
const allKeys = [Object.keys(codes).map(symbol => [2, symbol, symbol])];
save('all-keys', make(allKeys));
save('all-key-values', Object.values(codes));
save('current-mic', make([[[1, 'Mic', 'KC_MIC']]]));
save('legacy-mic', [[[1, 'Mic', 'KC_MIC']]]);
save('legacy-lpad', [[[1, 'Launchpad', 'KC_LPAD']]]);
save('bad-hash', {...make(macro), md5:'0'.repeat(32)});
save('other-device', make(macro, undefined, 875825248));
save('missing-names', {...make(macro), name:[]});
save('extra-metadata', {...make(macro), loop:[1]});
save('mouse-down', make([[[6, 'KC_MS_BTN1', 'Mouse1']]]));
save('mouse-up', make([[[7, 'KC_MS_BTN1', 'Mouse1']]]));
save('mouse-key', make([[[2, 'Mouse1', 'KC_MS_BTN1']]]));
save('unknown-command', make([[[99, 'unrecognized']]]));
save('unknown-symbol', make([[[1, 'Enter', 'KC_ENTER']]]));
save('numeric-symbol', make([[[1, 'A', 4]]]));
save('extra-event-data', make([[[1, 'A', 'KC_A', 42]]]));
save('boolean-type', make([[[true, 'A', 'KC_A']]]));
save('fractional-type', make([[[1.5, 'A', 'KC_A']]]));
save('negative-delay', make([[[4, -1]]]));
save('oversized-delay', make([[[4, 65536]]]));
save('fractional-delay', make([[[4, 1.5]]]));
save('boolean-delay', make([[[4, true]]]));
save('string-delay', make([[[4, '125']]]));
save('unicode-text', make([[[5, 'caffè']]]));
save('zero-text', make([[[5, 'a\u0000b']]]));
save('one-text', make([[[5, 'a\u0001b']]]));
save('empty-set', make([]));
save('too-many-slots', make(Array.from({length:65}, () => [])));
save('too-many-actions', make([Array.from({length:10000}, () => [4, 0])]));
save('non-array-slot', make([{}]));
save('non-array-event', make([[{}]]));
save('boundary-delays', make([[[4, -0], [4, 65535], [5, '']]]));
save('expectations', {macro, names, codes, canonicalMacro:JSON.stringify(macro)});
console.log('Launcher macro fixtures: protocol values + JavaScript JSON.stringify/MD5.');
