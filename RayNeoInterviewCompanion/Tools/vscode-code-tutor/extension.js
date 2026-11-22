// RayPrompt Code Tutor companion: compares the active editor with the iPhone's expected lines for the
// current code step and reports only booleans, the error count and the file name. Source never leaves.
const vscode = require('vscode');
const net = require('net');
const crypto = require('crypto');
const path = require('path');

let socket = null;
let expectation = null; // { blockID, language, structures: [string] }
let timer = null;

const squash = (text) => text.replace(/\s+/g, '');

function report() {
  const editor = vscode.window.activeTextEditor;
  if (!socket || !expectation || !editor) return;
  const text = squash(editor.document.getText());
  const present = expectation.structures.map((line) => text.includes(squash(line)));
  const errors = vscode.languages.getDiagnostics(editor.document.uri)
    .filter((d) => d.severity === vscode.DiagnosticSeverity.Error).length;
  send({ type: 'progress', blockID: expectation.blockID, file: path.basename(editor.document.fileName),
         language: editor.document.languageId, present, errors });
}

function send(message) { if (socket) socket.write(JSON.stringify(message) + '\n'); }
function schedule() { clearTimeout(timer); timer = setTimeout(report, 400); }

async function pair() {
  const address = await vscode.window.showInputBox({ prompt: 'iPhone address:port (shown in the app)' });
  const code = await vscode.window.showInputBox({ prompt: '6-digit pairing code', password: true });
  if (!address || !code) return;
  const [host, port] = address.split(':');
  disconnect();
  socket = net.createConnection({ host, port: Number(port) });
  let buffer = '';
  socket.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index));
      buffer = buffer.slice(index + 1);
      if (message.type === 'challenge') {
        const mac = crypto.createHmac('sha256', code).update(message.nonce).digest('hex');
        send({ type: 'hello', mac });
      } else if (message.type === 'paired') {
        vscode.window.showInformationMessage('Code Tutor: paired with iPhone');
      } else if (message.type === 'expect') {
        expectation = message;
        report();
      }
    }
  });
  socket.on('close', () => { socket = null; });
  socket.on('error', (error) => vscode.window.showErrorMessage(`Code Tutor: ${error.message}`));
}

function disconnect() { if (socket) socket.destroy(); socket = null; expectation = null; }

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('codeTutor.pair', pair),
    vscode.commands.registerCommand('codeTutor.disconnect', disconnect),
    vscode.workspace.onDidChangeTextDocument(schedule),
    vscode.window.onDidChangeActiveTextEditor(schedule),
    vscode.languages.onDidChangeDiagnostics(schedule),
  );
}

module.exports = { activate, deactivate: disconnect };
