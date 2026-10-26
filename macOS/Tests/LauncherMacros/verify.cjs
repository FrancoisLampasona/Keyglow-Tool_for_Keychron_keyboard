const fs = require('fs');
const crypto = require('crypto');
const assert = require('assert');
const directory = process.argv[2];
const read = name => JSON.parse(fs.readFileSync(directory + '/' + name + '.json', 'utf8'));
const expected = read('expectations');
function validate(file) {
  assert.deepStrictEqual(Object.keys(file), ['md5', 'macro', 'name']);
  assert.strictEqual(file.md5, crypto.createHash('md5').update(JSON.stringify(file.macro) + 875825249).digest('hex'));
}
// Labels are cosmetic; compare actions, exact symbols/numeric values, text, names,
// and their independent v11 wire encoding, including Tap versus Down/Up.
function wire(slots) {
  return slots.flatMap(slot => [...slot.flatMap(event => {
    if ([1, 2, 3].includes(event[0])) return [1, event[0], expected.codes[event[2]]];
    if (event[0] === 4) return [1, 4, ...Array.from(String(event[1]), char => char.charCodeAt(0)), 124];
    if (event[0] === 5) return Array.from(event[1], char => char.charCodeAt(0));
    throw Error('Unsupported event in output');
  }), 0]);
}
const native = read('native-export');
validate(native);
assert.deepStrictEqual(native.name, expected.names);
assert.deepStrictEqual(wire(native.macro), wire(expected.macro));
assert.deepStrictEqual(native.macro.map(slot => slot.map(event => event[0])), expected.macro.map(slot => slot.map(event => event[0])));
const allKeys = read('native-all-keys');
validate(allKeys);
assert.deepStrictEqual(wire(allKeys.macro), wire(read('all-keys').macro));
console.log('Independent JavaScript verification: both MD5 digests, slot order/names, all 194 symbols, event types, and exact v11 wire bytes passed.');
