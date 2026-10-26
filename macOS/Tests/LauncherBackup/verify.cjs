// Independent verification of the native export using Launcher's actual hash rule.
const fs = require('fs');
const assert = require('assert');
const crypto = require('crypto');
const directory = process.argv[2];
const file = JSON.parse(fs.readFileSync(directory + '/native-export.json', 'utf8'));
const definition = JSON.parse(fs.readFileSync('macOS/Resources/q6-max-iso.json', 'utf8'));
assert.strictEqual(file.id, 65536 * definition.vendorID + definition.productID);
assert.strictEqual(file.version, '1.0.0');
assert.strictEqual(file.MD5, crypto.createHash('md5').update(JSON.stringify(file.keymap)).digest('hex'));
assert.deepStrictEqual(file.keymap.map(layer => layer.map(entry => entry.val)), definition.defaultLayers);
assert.deepStrictEqual(file.knob.map(entry => [entry.left, entry.right]), definition.defaultEncoders);
for (const layer of file.keymap) {
  for (const [index, key] of layer.entries()) {
    assert.deepStrictEqual(Object.keys(key), ['col', 'row', 'val']);
    assert.strictEqual(key.col, index % 20);
    assert.strictEqual(key.row, Math.floor(index / 20));
  }
}
console.log('Independent JavaScript verification: Launcher identity, schema, MD5, four complete 6×20 layers, four knob pairs passed.');
