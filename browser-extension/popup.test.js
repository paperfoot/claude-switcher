import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

class FakeElement {
  constructor() {
    this.textContent = '';
    this.children = [];
    this.disabled = false;
    this.onclick = null;
  }
  append(child) { this.children.push(child); }
  replaceChildren() { this.children = []; }
}

async function openPopup(reply) {
  const elements = {'#message': new FakeElement(), '#accounts': new FakeElement(), '#add': new FakeElement(), '#save': new FakeElement()};
  const document = {
    querySelector: selector => elements[selector],
    querySelectorAll: () => [elements['#add'], elements['#save']],
    createElement: () => new FakeElement(),
  };
  const chrome = {runtime: {sendMessage: async message => reply(message)}};
  const source = await readFile(new URL('./popup.js', import.meta.url), 'utf8');
  vm.runInNewContext(source, {chrome, document});
  for (let i = 0; i < 20; i++) await new Promise(resolve => setImmediate(resolve));
  return elements;
}

test('the popup explains companion error codes', async () => {
  const elements = await openPopup(() => ({ok: false, error: 'keychain_unavailable', message: 'raw text'}));
  assert.equal(elements['#message'].textContent, 'Your Keychain is locked. Unlock it and try again.');
  assert.equal(elements['#save'].disabled, false);
});

test('the popup falls back to the reply text for a code it does not know', async () => {
  const elements = await openPopup(() => ({ok: false, error: 'new_code', message: 'Something specific happened.'}));
  assert.equal(elements['#message'].textContent, 'Something specific happened.');
});

test('the popup lists saved accounts and marks the current one', async () => {
  const elements = await openPopup(() => ({ok: true, email: 'a@example.com', accounts: ['a@example.com', 'b@example.com']}));
  assert.deepEqual(elements['#accounts'].children.map(child => child.textContent), ['✓  a@example.com', 'b@example.com']);
  assert.equal(elements['#message'].textContent, 'Chrome: a@example.com');
});
