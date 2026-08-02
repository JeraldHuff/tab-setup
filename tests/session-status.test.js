// Unit tests for vscode-extension/lib/session-status.js.
// Uses Node's built-in runner — no dependencies. Run with: node --test
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { readSessionFile } = require('../vscode-extension/lib/session-status');

function makeSessionsDir(files = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tab-setup-test-'));
    for (const [name, content] of Object.entries(files)) {
        fs.writeFileSync(path.join(dir, name), content);
    }
    return dir;
}

test('returns null when the sessions dir does not exist', () => {
    assert.equal(readSessionFile('/nonexistent/tab-setup-sessions', 'abc'), null);
});

test('returns null when the dir has no session files', () => {
    const dir = makeSessionsDir();
    assert.equal(readSessionFile(dir, 'abc'), null);
});

test('returns the session matching sessionId', () => {
    const dir = makeSessionsDir({
        'a.json': JSON.stringify({ sessionId: 'aaa', status: 'busy' }),
        'b.json': JSON.stringify({ sessionId: 'bbb', status: 'idle' }),
    });
    const session = readSessionFile(dir, 'bbb');
    assert.deepEqual(session, { sessionId: 'bbb', status: 'idle' });
});

test('returns null when no session matches sessionId', () => {
    const dir = makeSessionsDir({
        'a.json': JSON.stringify({ sessionId: 'aaa', status: 'busy' }),
    });
    assert.equal(readSessionFile(dir, 'zzz'), null);
});

test('falsy sessionId matches the first session found', () => {
    const dir = makeSessionsDir({
        'a.json': JSON.stringify({ sessionId: 'aaa', status: 'busy' }),
    });
    const session = readSessionFile(dir, undefined);
    assert.deepEqual(session, { sessionId: 'aaa', status: 'busy' });
});

test('skips malformed JSON instead of throwing', () => {
    const dir = makeSessionsDir({
        'broken.json': '{ this is not json',
        'ok.json': JSON.stringify({ sessionId: 'ok', status: 'idle' }),
    });
    const session = readSessionFile(dir, 'ok');
    assert.deepEqual(session, { sessionId: 'ok', status: 'idle' });
});

test('ignores non-.json files', () => {
    const dir = makeSessionsDir({
        'notes.txt': JSON.stringify({ sessionId: 'txt', status: 'idle' }),
    });
    assert.equal(readSessionFile(dir, undefined), null);
});

test('a half-written (empty) session file is skipped, not treated as a session', () => {
    const dir = makeSessionsDir({
        'empty.json': '',
        'ok.json': JSON.stringify({ sessionId: 'ok', status: 'busy' }),
    });
    const session = readSessionFile(dir, undefined);
    assert.deepEqual(session, { sessionId: 'ok', status: 'busy' });
});
