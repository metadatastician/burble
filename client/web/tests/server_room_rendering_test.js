// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { test } from './runner.js';

// Exercise the shipped server client's actual renderer without starting the
// application, opening a browser, or allowing HTML interpretation in the fixture.
const source = readFileSync(new URL('../../../server/priv/static/index.html', import.meta.url), 'utf8');
const renderer = source.match(/    function renderRoomList\(rooms\) \{[\s\S]*?\n    \}/g);
assert.equal(renderer?.length, 1, 'the shipped room renderer must be found exactly once');

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.textContent = ''; }
  set innerHTML(value) {
    assert.equal(value, '', 'room data must never reach an HTML sink');
    this.children = [];
  }
  append(...children) { this.children.push(...children); }
  appendChild(child) { this.append(child); }
}

test('server room labels and counts stay literal while room selection works', () => {
  const list = new Element('div');
  const selected = [];
  const room = {
    id: 'room-1',
    name: '<img src=x onerror="throw 1"> & "friends"',
    participant_count: '<svg onload="throw 2">',
  };
  const render = runInNewContext(`${renderer[0]}\nrenderRoomList`, {
    document: {
      getElementById: id => { assert.equal(id, 'room-list'); return list; },
      createElement: tag => new Element(tag),
    },
    state: { currentRoom: room.id },
    joinRoom: (...args) => selected.push(args),
  });
  render([room]);
  assert.equal(list.children.length, 1);
  const button = list.children[0];
  assert.equal(button.tag, 'button');
  assert.equal(button.className, 'room-btn active');
  assert.equal(button.textContent, room.name);
  assert.equal(button.children[0], ' ');
  assert.equal(button.children[1].tag, 'span');
  assert.equal(button.children[1].className, 'count');
  assert.equal(button.children[1].textContent, room.participant_count);
  button.onclick();
  assert.deepEqual(selected, [[room.id, room.name]]);
  render([{ id: 'room-2', name: 'General', participant_count: 3 }]);
  assert.equal(list.children.length, 1, 'refresh replaces old rooms');
  assert.equal(list.children[0].className, 'room-btn');
  assert.equal(list.children[0].children[1].textContent, '3');
  render([]);
  assert.equal(list.children.length, 0);
});
