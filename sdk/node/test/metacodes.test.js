'use strict';
// End-to-end tests of the Node package against the real AgentCore library and
// the addon in prebuilds/. Without them the suite skips, unless
// METACODES_NODE_SDK_REQUIRE_LIB=1, which CI sets so a missing build fails.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const metacodes = require('..');
const { startMockProvider } = require('./mock_provider');

const addon = path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`, 'metacodes.node');
const available = fs.existsSync(addon) && metacodes.candidateLibraryPaths().some((candidate) => fs.existsSync(candidate));
const skip = !available && process.env.METACODES_NODE_SDK_REQUIRE_LIB !== '1'
  ? 'addon or AgentCore library not built; see README.md'
  : false;

function workspace(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'metacodes-node-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

async function withProvider(t, script) {
  const provider = await startMockProvider(script);
  t.after(() => provider.close());
  return provider;
}

function open(t, runtimeOptions, provider, root, sessionOptions = {}) {
  const runtime = new metacodes.Runtime(runtimeOptions);
  t.after(() => runtime.close());
  const session = runtime.session('mock-model', {
    baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root, ...sessionOptions,
  });
  return { runtime, session };
}

test('a text run returns the final answer, events and usage', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'hello from the mock']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  const result = await session.run('say hello', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  assert.equal(result.text, 'hello from the mock');
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.turns, 1);
  assert.equal(result.usage.input_tokens, 11);
  assert.ok(tags.includes('text_chunk'));
  assert.ok(tags.includes('output_segment_end'));
  assert.match(JSON.stringify(provider.requests[0].messages), /say hello/);
});

test('every event of a Run arrives before its Promise settles', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ordered']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  await session.run('go', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  const last = tags.at(-1);
  assert.equal(last, 'run_state');
});

test('an async JavaScript tool result reaches the model', { skip }, async (t) => {
  const calls = [];
  const add = metacodes.tool({
    name: 'add',
    description: 'Add two integers.',
    inputSchema: { type: 'object', properties: { a: { type: 'integer' }, b: { type: 'integer' } }, required: ['a', 'b'] },
    handler: async ({ a, b }) => {
      calls.push([a, b]);
      await new Promise((resolve) => setTimeout(resolve, 10));
      return String(a + b);
    },
  });
  const provider = await withProvider(t, [['tool', 'add', { a: 2, b: 3 }], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [add] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('add 2 and 3');
  assert.deepEqual(calls, [[2, 3]]);
  assert.equal(result.text, 'saw: 5');
  assert.equal(result.toolCalls, 1);
  assert.ok(provider.requests[0].tools.some((advertised) => advertised.name === 'add'));
});

test('a throwing tool becomes a model-visible error', { skip }, async (t) => {
  const broken = metacodes.tool({ name: 'broken', handler: () => { throw new Error('disk on fire'); } });
  const provider = await withProvider(t, [['tool', 'broken', {}], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [broken] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('try it');
  assert.match(result.text, /disk on fire/);
  assert.equal(result.stopReason, 'end_turn');
});

test('the built-in Read tool reads the workspace', { skip }, async (t) => {
  const root = workspace(t);
  fs.writeFileSync(path.join(root, 'notes.txt'), 'the secret is 42\n');
  const provider = await withProvider(t, [['tool', 'Read', { file_path: 'notes.txt' }], ['echo']]);
  const { session } = open(t, { tools: ['Read'] }, provider, root);
  const result = await session.run('read notes.txt');
  assert.match(result.text, /the secret is 42/);
});

test('Runtime points RG_BIN at the ripgrep staged beside the library', { skip }, (t) => {
  const saved = process.env.RG_BIN;
  delete process.env.RG_BIN;
  t.after(() => { if (saved === undefined) delete process.env.RG_BIN; else process.env.RG_BIN = saved; });
  const runtime = new metacodes.Runtime({ tools: ['Grep'] });
  t.after(() => runtime.close());
  const staged = path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`, 'rg');
  if (!fs.existsSync(staged)) return t.skip('no ripgrep staged');
  assert.ok(process.env.RG_BIN && fs.realpathSync(process.env.RG_BIN) === fs.realpathSync(staged));
});

test('a permission request reaches the handler and a deny holds', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const requests = [];
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['echo']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: (request) => { requests.push(request); return request.denyOnce(); },
  });
  const result = await session.run('write a file');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'permission');
  assert.equal(requests[0].data.tool.name, 'Write');
  assert.equal(fs.existsSync(target), false);
  assert.equal(result.stopReason, 'end_turn');
});

test('an async allow lets the write happen', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'written' }], ['text', 'done']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: async (request) => request.allowOnce(),
  });
  const result = await session.run('write a file');
  assert.equal(fs.readFileSync(target, 'utf8'), 'written');
  assert.equal(result.text, 'done');
});

test('without a handler the write is not allowed', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['text', 'ok']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root);
  await session.run('write a file');
  assert.equal(fs.existsSync(target), false);
});

test('stream yields events and then the result', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'streamed']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const stream = session.stream('go');
  const tags = [];
  for await (const event of stream) tags.push(Object.keys(event)[0]);
  assert.ok(tags.includes('text_chunk'));
  assert.equal((await stream.result).text, 'streamed');
});

test('a throwing listener rejects the Run and the session survives', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'answer'], ['text', 'answer']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  await assert.rejects(session.run('one', { onEvent: () => { throw new TypeError('listener bug'); } }), /listener bug/);
  const result = await session.run('two');
  assert.equal(result.text, 'answer');
});

test('a second concurrent run on one session is refused', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'first'], ['text', 'second']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const first = session.run('one');
  await assert.rejects(session.run('two'), /already active/);
  assert.equal((await first).text, 'first');
});

test('two sessions run concurrently', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'same'], ['text', 'same']]);
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const root = workspace(t);
  const options = { baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root };
  const [a, b] = await Promise.all([
    runtime.session('mock-model', options).run('a'),
    runtime.session('mock-model', options).run('b'),
  ]);
  assert.equal(a.text, 'same');
  assert.equal(b.text, 'same');
});

test('a shell tool requires a shell policy', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const runtime = new metacodes.Runtime({ tools: ['Bash'] });
  t.after(() => runtime.close());
  assert.throws(
    () => runtime.session('mock-model', { baseUrl: provider.baseUrl, apiKey: 'k', workspace: workspace(t), tools: ['Bash'] }),
    (error) => error.code === 'INVALID_ARGUMENT',
  );
});

test('describe and setModel', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  assert.match(JSON.stringify(session.describe()), /mock-model/);
  session.setModel('mock-model-2');
  assert.match(JSON.stringify(session.describe()), /mock-model-2/);
});

test('unknown built-in tools are rejected', { skip }, () => {
  assert.throws(() => new metacodes.Runtime({ tools: ['Telepathy'] }), /unknown built-in tools/);
});
