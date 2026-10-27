#!/usr/bin/env node
// megalooper as a tool for an AI app: the Claude Desktop extension's bridge,
// an MCP server over stdio (docs/ai.md). It does what tools/megalooper-mcp.py
// does, in Node, because Claude Desktop runs its extensions' Node itself: an
// extension then needs nothing installed. Node's own modules only.
//
// It knows no music. It turns the app's tool calls into requests to
// megalooper (classes/MegaRemote.sc): the request a JSON file in megalooper's
// remote folder, an OSC message to megalooper's port naming it with the
// token, the answer a reply file there. Where megalooper listens, and the
// token, it reads from remote.json, which megalooper writes while AI APPS
// is switched on in its Setup view (MEGALOOPER_REMOTE names another file).
// The tools it offers are mcp-tools.json's: beside this file in the
// extension, tools/mcp-tools.json in the repository.
'use strict';

const crypto = require('crypto');
const dgram = require('dgram');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

const SPEC = JSON.parse(fs.readFileSync(
  [path.join(__dirname, 'mcp-tools.json'), path.join(__dirname, '..', '..', 'mcp-tools.json')]
    .find((p) => fs.existsSync(p)), 'utf8'));
const TOOL_NAMES = SPEC.tools.map((t) => t.name);
const PASSED_ON = new Set(SPEC.passedOn);
const ALWAYS_KEPT = new Set(['format', 'version', 'profile', 'standalone', 'tempo', 'aiChanges', 'aiChangeLabels']);
const REPLY_TIMEOUT = Number(process.env.MEGALOOPER_REPLY_TIMEOUT) || 10;
const POLL_MS = 20;

class NotReachable extends Error {}

// ---- megalooper's side ----------------------------------------------------------

function userRoot() {
  const base = process.platform === 'darwin'
    ? path.join(os.homedir(), 'Library', 'Application Support', 'SuperCollider')
    : path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'SuperCollider');
  return path.join(base, 'megalooper');
}

function handshakePath() {
  return process.env.MEGALOOPER_REMOTE || path.join(userRoot(), 'remote.json');
}

function readHandshake() {
  const p = handshakePath();
  let hs;
  try {
    hs = JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    if (e.code === 'ENOENT') {
      throw new NotReachable(`megalooper is not running, or AI apps are not let in (no ${p}). Start megalooper, `
        + 'switch AI APPS on in its Setup view, then ask again.');
    }
    throw new NotReachable(`megalooper's handshake ${p} can't be read (${e.message}).`);
  }
  if (!hs || hs.format !== 'megalooper remote' || !Number.isInteger(hs.port) || !hs.token || !hs.dir) {
    throw new NotReachable(`${p} is not megalooper's handshake.`);
  }
  return hs;
}

function pidAlive(pid) {
  if (!Number.isInteger(pid)) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code !== 'ESRCH';
  }
}

function oscString(s) {
  const b = Buffer.from(s + '\0', 'utf8');
  return Buffer.concat([b, Buffer.alloc((4 - (b.length % 4)) % 4)]);
}

function oscMessage(address, ...strings) {
  return Buffer.concat([oscString(address), oscString(',' + 's'.repeat(strings.length)), ...strings.map(oscString)]);
}

function send(port, message) {
  return new Promise((resolve, reject) => {
    const sock = dgram.createSocket('udp4');
    sock.send(message, port, '127.0.0.1', (err) => {
      sock.close();
      if (err) reject(err); else resolve();
    });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// megalooper's answer to `command`: its result, or a NotReachable.
async function ask(command, args) {
  const hs = readHandshake();
  const rid = 'mcp-' + crypto.randomBytes(16).toString('hex');
  const req = path.join(hs.dir, rid + '.request.json');
  const rep = path.join(hs.dir, rid + '.reply.json');
  const body = { command };
  if (args !== undefined) body.args = args;
  try {
    fs.writeFileSync(req + '.tmp', JSON.stringify(body));
    fs.renameSync(req + '.tmp', req);
  } catch (e) {
    throw new NotReachable(`the request could not be written to ${hs.dir} (${e.message}).`);
  }
  let reply;
  try {
    await send(hs.port, oscMessage(hs.oscPath || '/megalooper/remote', hs.token, rid));
    const deadline = Date.now() + REPLY_TIMEOUT * 1000;
    while (!fs.existsSync(rep)) {
      if (Date.now() > deadline) {
        if (!pidAlive(hs.pid)) {
          throw new NotReachable(`megalooper is not running (it quit without removing ${handshakePath()}). `
            + 'Start it, switch AI APPS on in its Setup view, then ask again.');
        }
        throw new NotReachable(`megalooper did not answer in ${REPLY_TIMEOUT} s. Is it busy, or stuck? `
          + 'Restarting it writes a new handshake.');
      }
      await sleep(POLL_MS);
    }
    reply = JSON.parse(fs.readFileSync(rep, 'utf8'));
  } finally {
    for (const p of [req, rep]) {
      try { fs.unlinkSync(p); } catch (e) { /* gone already */ }
    }
  }
  if (!reply || typeof reply !== 'object' || Array.isArray(reply)) {
    throw new NotReachable("megalooper's answer was not understood.");
  }
  if (!reply.ok) throw new NotReachable(reply.error || 'megalooper refused the request.');
  return reply.result;
}

// ---- the tools ----------------------------------------------------------------------

// The text of a tool's answer, and whether it is an error.
async function callTool(name, args) {
  args = args || {};
  try {
    if (name === 'get_context') {
      let ctx = await ask('context');
      const parts = args.parts;
      if (Array.isArray(parts) && parts.length && ctx && typeof ctx === 'object') {
        const keep = new Set([...ALWAYS_KEPT, ...parts]);
        ctx = Object.fromEntries(Object.entries(ctx).filter(([k]) => keep.has(k)));
      }
      return [JSON.stringify(ctx), false];
    }
    if (name === 'describe') return [JSON.stringify(await ask('describe', { topic: args.topic })), false];
    if (PASSED_ON.has(name)) return [JSON.stringify(await ask(name, args)), false];
    return [`There is no tool ${name}.`, true];
  } catch (e) {
    if (e instanceof NotReachable) return [e.message, true];
    throw e;
  }
}

// ---- MCP: JSON-RPC 2.0, one message a line ----------------------------------------------

const result = (id, r) => ({ jsonrpc: '2.0', id, result: r });
const error = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

// The response to one message, or null for a notification.
async function handle(msg) {
  if (!msg || typeof msg !== 'object' || Array.isArray(msg) || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
    return error(msg && typeof msg === 'object' && !Array.isArray(msg) && 'id' in msg ? msg.id : null, -32600, 'Invalid Request');
  }
  if (!('id' in msg)) return null;
  const { method, id } = msg;
  const params = msg.params || {};
  if (method === 'initialize') {
    const asked = params.protocolVersion;
    return result(id, {
      protocolVersion: SPEC.protocolVersions.includes(asked) ? asked : SPEC.protocolVersions[0],
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: SPEC.serverName, version: SPEC.serverVersion },
      instructions: SPEC.instructions,
    });
  }
  if (method === 'ping') return result(id, {});
  if (method === 'tools/list') return result(id, { tools: SPEC.tools });
  if (method === 'tools/call') {
    if (!TOOL_NAMES.includes(params.name)) return error(id, -32602, `Unknown tool: ${params.name}`);
    const [text, isError] = await callTool(params.name, params.arguments);
    return result(id, { content: [{ type: 'text', text }], isError });
  }
  return error(id, -32601, `Method not found: ${method}`);
}

function serve() {
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  // One message at a time, in the order they came: an answer waits for the
  // one before it.
  let chain = Promise.resolve();
  rl.on('line', (line) => {
    line = line.trim();
    if (!line) return;
    chain = chain.then(async () => {
      let msg;
      let out;
      try {
        msg = JSON.parse(line);
      } catch (e) {
        out = error(null, -32700, 'Parse error');
      }
      if (out === undefined) {
        try {
          out = await handle(msg);
        } catch (e) { // a bug here must not end the session
          process.stderr.write(`megalooper-mcp: ${e && e.stack ? e.stack : e}\n`);
          out = error(msg && typeof msg === 'object' && 'id' in msg ? msg.id : null, -32603, 'Internal error');
        }
      }
      if (out) process.stdout.write(JSON.stringify(out) + '\n');
    });
  });
}

module.exports = { oscMessage, handle, callTool };

if (require.main === module) serve();
