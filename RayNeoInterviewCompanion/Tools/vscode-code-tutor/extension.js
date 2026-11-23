// RayPrompt Code Tutor companion. VS Code ↔ encrypted local link ↔ RayPrompt (iPhone) → BLE → RayNeo.
// Sends metadata by default (file name, language, position, current symbol, structure checks, diagnostic
// summaries, task results). Source code leaves the Mac only for Explain Selection / Explain Error, after you
// confirm, never from sensitive files, with secrets redacted. The protocol lives in protocol.js.
'use strict';
const vscode = require('vscode');
const net = require('net');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const p = require('./protocol');

const TRUST_KEY = 'rayprompt.trust';
let link;

class Link {
  constructor(context) {
    this.context = context;
    this.output = vscode.window.createOutputChannel('RayPrompt');
    this.statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
    this.statusBar.command = 'rayprompt.showLog';
    this.statusBar.show();
    this.socket = null; this.channel = null; this.attempt = 0; this.manual = false;
    this.expectation = null; this.lastSent = new Map(); this.lastEdit = 0; this.autoProgress = true;
    this.metrics = { connects: 0, reconnects: 0, failures: 0, rtt: null, pingSent: 0 };
    this.setState('offline');
  }

  log(message) { this.output.appendLine(`[${new Date().toISOString()}] ${message}`); }
  setState(state, detail = '') {
    this.state = state;
    const icon = { connected: '$(broadcast)', connecting: '$(sync~spin)', reconnecting: '$(sync~spin)', offline: '$(circle-slash)', unpaired: '$(key)' }[state] || '$(question)';
    this.statusBar.text = `${icon} RayPrompt: ${state}${detail ? ` (${detail})` : ''}`;
    this.statusBar.tooltip = `RayPrompt link: ${state}. RTT ${this.metrics.rtt ?? '–'} ms. Click for the log.`;
  }

  deviceID() {
    let id = this.context.globalState.get('rayprompt.deviceID');
    if (!id) { id = crypto.randomUUID(); this.context.globalState.update('rayprompt.deviceID', id); }
    return id;
  }
  async trust() { const raw = await this.context.secrets.get(TRUST_KEY); return raw ? JSON.parse(raw) : null; }
  async saveTrust(trust) { await this.context.secrets.store(TRUST_KEY, JSON.stringify(trust)); }

  /// Connect with the stored trust (reconnect) or a pairing code (first time).
  async connect({ address, pairCode } = {}) {
    clearTimeout(this.reconnectTimer);
    this.manual = false;
    const trust = await this.trust();
    const target = address || trust?.address;
    if (!target) return this.setState('unpaired', 'run “RayPrompt: Pair with iPhone”');
    if (!pairCode && !trust) return this.setState('unpaired');
    const [host, portText] = target.split(':');
    this.close(false);
    this.setState(this.attempt ? 'reconnecting' : 'connecting');
    const socket = net.createConnection({ host, port: Number(portText) || 48654, timeout: 8000 });
    this.socket = socket;
    let buffer = '', handshake = null;
    socket.on('timeout', () => socket.destroy(new Error('connection timed out')));
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      if (buffer.length > p.MAX_LINE) return socket.destroy(new Error('message too large'));
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
        try { handshake = this.onLine(JSON.parse(line), handshake, { pairCode, trust, target }); }
        catch (error) { this.log(`Protocol error: ${error.message}`); socket.destroy(); return; }
      }
    });
    socket.on('error', (error) => { this.metrics.failures += 1; this.log(`Connection error: ${error.message}`); });
    socket.on('close', () => this.onClose(socket));
  }

  onLine(message, handshake, { pairCode, trust, target }) {
    if (!this.channel) {
      if (message.type === 'hello') {
        const state = p.clientHandshake(message, { deviceID: this.deviceID(), name: `VS Code on ${os.hostname()}`, code: pairCode,
                                                    trust: pairCode ? null : { key: Buffer.from(trust.key, 'base64') } });
        state.service = message.service;
        this.socket.write(JSON.stringify(state.message) + '\n');
        return state;
      }
      if (message.type === 'rejected') {
        this.log(`iPhone rejected the connection: ${message.reason}`);
        if (/not paired|expired/.test(message.reason || '')) { this.context.secrets.delete(TRUST_KEY); this.setState('unpaired', message.reason); this.manual = true; }
        return handshake;
      }
      if ((message.type === 'paired' || message.type === 'resumed') && handshake) {
        if (message.mac !== handshake.expect) throw new Error('the iPhone failed to authenticate');
        this.channel = new p.SecureChannel(handshake.keys, 'client');
        if (message.type === 'paired') {
          this.saveTrust({ key: p.b64(handshake.trustKey), address: target, service: handshake.service, pairedAt: Date.now() });
          vscode.window.showInformationMessage('RayPrompt: paired with your iPhone.');
        } else if (handshake.service) {
          this.trust().then((t) => t && this.saveTrust({ ...t, address: target, service: handshake.service }));
        }
        this.metrics.connects += 1; if (this.attempt) this.metrics.reconnects += 1;
        this.attempt = 0;
        this.setState('connected');
        this.log(`${message.type === 'paired' ? 'Paired' : 'Reconnected'} (encrypted session)`);
        this.startHeartbeat();
        this.lastSent.clear();
        this.sendState(true);
        return handshake;
      }
      throw new Error(`unexpected handshake message ${message.type}`);
    }
    const body = this.channel.open(message);
    if (body.type === 'pong') this.metrics.rtt = Date.now() - this.pingSentAt;
    if (body.type === 'expect') { this.expectation = body; this.reportProgress(); }
    return handshake;
  }

  onClose(socket) {
    if (socket !== this.socket) return;
    clearInterval(this.heartbeat);
    this.channel = null; this.socket = null;
    if (this.manual) return this.setState(this.state === 'unpaired' ? 'unpaired' : 'offline');
    this.scheduleReconnect();
  }

  async scheduleReconnect() {
    const delay = p.backoff(this.attempt);
    this.attempt += 1;
    this.setState('reconnecting', `in ${Math.round(delay / 1000)} s`);
    this.reconnectTimer = setTimeout(async () => {
      // After a few failures the iPhone's address may have changed (network change): ask Bonjour.
      if (this.attempt >= 3) {
        const trust = await this.trust();
        const found = trust?.service ? await resolveService(trust.service) : null;
        if (found && found !== trust.address) { this.log(`Found the iPhone at ${found}`); await this.saveTrust({ ...trust, address: found }); }
      }
      this.connect();
    }, delay);
  }

  startHeartbeat() {
    clearInterval(this.heartbeat);
    this.heartbeat = setInterval(() => { this.pingSentAt = Date.now(); this.send({ type: 'ping', id: ++this.metrics.pingSent }); }, 10_000);
  }

  send(body) {
    if (!this.channel || !this.socket) return false;
    this.socket.write(JSON.stringify(this.channel.seal(body)) + '\n');
    return true;
  }

  /// Sends only when the content changed since the last message of the same type.
  sendChanged(type, body, force = false) {
    const key = JSON.stringify(body);
    if (!force && this.lastSent.get(type) === key) return;
    if (this.send({ type, ...body })) this.lastSent.set(type, key);
  }

  close(manual = true) {
    this.manual = manual;
    clearInterval(this.heartbeat);
    clearTimeout(this.reconnectTimer);
    if (this.channel) this.send({ type: 'bye' });
    if (this.socket) this.socket.destroy();
    this.socket = null; this.channel = null;
    if (manual) this.setState('offline');
  }

  // MARK: Editor awareness (metadata only)

  async sendState(force = false) {
    const editor = vscode.window.activeTextEditor;
    if (!editor) return;
    const file = editor.document.fileName;
    const sensitive = p.isSensitiveFile(file);
    const position = editor.selection.active;
    const symbol = sensitive ? null : await currentSymbol(editor.document, position);
    this.sendChanged('state', {
      file: sensitive ? '(private file)' : path.basename(file), language: editor.document.languageId,
      line: position.line + 1, column: position.character + 1, symbol,
      selectionLines: editor.selection.isEmpty ? 0 : editor.selection.end.line - editor.selection.start.line + 1,
    }, force);
    this.sendDiagnostics(force);
  }

  sendDiagnostics(force = false) {
    const editor = vscode.window.activeTextEditor;
    if (!editor || p.isSensitiveFile(editor.document.fileName)) return;
    const all = vscode.languages.getDiagnostics(editor.document.uri);
    const severity = (d) => ['error', 'warning', 'info', 'hint'][d.severity] || 'info';
    const relevant = all.filter((d) => d.severity <= vscode.DiagnosticSeverity.Warning).slice(0, 10);
    this.sendChanged('diagnostics', {
      errors: all.filter((d) => d.severity === vscode.DiagnosticSeverity.Error).length,
      warnings: all.filter((d) => d.severity === vscode.DiagnosticSeverity.Warning).length,
      stable: Date.now() - this.lastEdit > 1400,
      diagnostics: relevant.map((d) => ({ message: p.redact(d.message).slice(0, 200), severity: severity(d), line: d.range.start.line + 1,
                                          source: d.source, code: typeof d.code === 'object' ? String(d.code.value) : d.code && String(d.code) })),
    }, force);
  }

  /// Structure check for the current walkthrough step: expected lines present (normalised) and expected
  /// names known to the language service, plus the error count. Presence is evidence, not proof.
  async reportProgress() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || !this.expectation || !this.autoProgress || p.isSensitiveFile(editor.document.fileName)) return;
    const symbols = await documentSymbols(editor.document);
    const present = p.structurePresence(editor.document.getText(), this.expectation.structures || [], symbols);
    const errors = vscode.languages.getDiagnostics(editor.document.uri).filter((d) => d.severity === vscode.DiagnosticSeverity.Error).length;
    this.sendChanged('progress', { blockID: this.expectation.blockID, file: path.basename(editor.document.fileName),
                                   language: editor.document.languageId, present, errors, stable: true });
  }
}

async function documentSymbols(document) {
  try {
    const symbols = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', document.uri) || [];
    const names = new Set();
    const walk = (list) => list.forEach((s) => { names.add(s.name); if (s.children) walk(s.children); });
    walk(symbols);
    return names.size ? names : null; // no language service: fall back to text checks only
  } catch { return null; }
}

async function currentSymbol(document, position) {
  try {
    const symbols = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', document.uri) || [];
    let found = null;
    const walk = (list) => list.forEach((s) => { if (s.range && s.range.contains(position)) { found = s.name; if (s.children) walk(s.children); } });
    walk(symbols);
    return found;
  } catch { return null; }
}

/// macOS Bonjour lookup of the iPhone's service (after a network change). Resolves host:port or null.
function resolveService(name) {
  return new Promise((resolve) => {
    const child = execFile('dns-sd', ['-L', name, '_codetutor._tcp', 'local.'], { timeout: 3000 }, () => resolve(null));
    child.stdout.on('data', (data) => {
      const match = /can be reached at\s+(\S+?)\.?:(\d+)/.exec(String(data));
      if (match) { resolve(`${match[1]}:${match[2]}`); child.kill(); }
    });
  });
}

async function confirmSend(what) {
  const choice = await vscode.window.showWarningMessage(`Send ${what} to RayPrompt on your iPhone? Secrets are redacted; sensitive files are never sent.`, { modal: true }, 'Send');
  return choice === 'Send';
}

function activate(context) {
  link = new Link(context);
  let stateTimer, progressTimer;
  const scheduleState = () => { clearTimeout(stateTimer); stateTimer = setTimeout(() => link.sendState(), 250); };
  const scheduleProgress = () => {
    link.lastEdit = Date.now();
    clearTimeout(progressTimer);
    // Wait until editing pauses, then check the step and re-send diagnostics as stable.
    progressTimer = setTimeout(() => { link.reportProgress(); link.sendDiagnostics(); }, 1500);
  };
  context.subscriptions.push(
    vscode.commands.registerCommand('rayprompt.pair', async () => {
      const trust = await link.trust();
      const address = await vscode.window.showInputBox({ prompt: 'iPhone address:port (shown in RayPrompt › Settings)', value: trust?.address || '' });
      const code = address && await vscode.window.showInputBox({ prompt: 'Pairing code shown on the iPhone (XXXXX-XXXXX)', password: true });
      if (address && code) link.connect({ address, pairCode: code });
    }),
    vscode.commands.registerCommand('rayprompt.reconnect', () => { link.attempt = 0; link.connect(); }),
    vscode.commands.registerCommand('rayprompt.disconnect', () => link.close(true)),
    vscode.commands.registerCommand('rayprompt.forget', async () => {
      link.close(true);
      await context.secrets.delete(TRUST_KEY);
      link.setState('unpaired');
      vscode.window.showInformationMessage('RayPrompt: iPhone forgotten here. Also tap Forget on the iPhone to revoke it there.');
    }),
    vscode.commands.registerCommand('rayprompt.explainSelection', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.selection.isEmpty) return;
      const code = p.excerpt(editor.document.fileName, editor.document.getText(editor.selection));
      if (code === null) return vscode.window.showErrorMessage('RayPrompt: this file looks sensitive; nothing was sent.');
      if (!(await confirmSend(`the selected ${editor.selection.end.line - editor.selection.start.line + 1} line(s)`))) return;
      link.send({ type: 'explain', code, language: editor.document.languageId, file: path.basename(editor.document.fileName) });
    }),
    vscode.commands.registerCommand('rayprompt.explainError', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;
      const line = editor.selection.active.line;
      const diagnostics = vscode.languages.getDiagnostics(editor.document.uri)
        .filter((d) => d.severity === vscode.DiagnosticSeverity.Error)
        .sort((a, b) => Math.abs(a.range.start.line - line) - Math.abs(b.range.start.line - line));
      const d = diagnostics[0];
      if (!d) return vscode.window.showInformationMessage('RayPrompt: no error near the cursor.');
      let code;
      if (!p.isSensitiveFile(editor.document.fileName) && await confirmSend('the 7 lines around the error')) {
        const start = Math.max(0, d.range.start.line - 3), end = Math.min(editor.document.lineCount - 1, d.range.start.line + 3);
        code = p.excerpt(editor.document.fileName, editor.document.getText(new vscode.Range(start, 0, end, Number.MAX_SAFE_INTEGER)));
      }
      link.send({ type: 'help', code, diagnostics: [{ message: p.redact(d.message).slice(0, 200), severity: 'error', line: d.range.start.line + 1, source: d.source }] });
    }),
    vscode.commands.registerCommand('rayprompt.dismiss', () => link.send({ type: 'dismiss' })),
    vscode.commands.registerCommand('rayprompt.toggleAutoProgress', () => {
      link.autoProgress = !link.autoProgress;
      link.send({ type: 'auto', enabled: link.autoProgress });
      vscode.window.showInformationMessage(`RayPrompt: automatic step progression ${link.autoProgress ? 'on' : 'off'}.`);
    }),
    vscode.commands.registerCommand('rayprompt.showLog', () => {
      link.output.appendLine(`Metrics: ${JSON.stringify(link.metrics)}`);
      link.output.show();
    }),
    vscode.window.onDidChangeActiveTextEditor(() => { scheduleState(); scheduleProgress(); }),
    vscode.window.onDidChangeTextEditorSelection(scheduleState),
    vscode.workspace.onDidChangeTextDocument((e) => { if (e.document === vscode.window.activeTextEditor?.document) scheduleProgress(); }),
    vscode.languages.onDidChangeDiagnostics(() => link.sendDiagnostics()),
    vscode.tasks.onDidEndTaskProcess((e) => {
      const task = e.execution.task;
      const kind = task.group === vscode.TaskGroup.Test || /test/i.test(task.name) ? 'test'
        : task.group === vscode.TaskGroup.Build || /build|compile|tsc/i.test(task.name) ? 'build' : null;
      // Only what the task runner actually reported: its exit code.
      if (kind) link.send({ type: 'task', task: { name: task.name, kind, exitCode: e.exitCode } });
    }),
    { dispose: () => link.close(true) },
  );
  link.connect(); // trusted iPhone: reconnect automatically
}

module.exports = { activate, deactivate: () => link && link.close(true) };
