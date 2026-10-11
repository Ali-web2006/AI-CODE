// Strict Luau type check of every script in the project, with the official Luau analyzer (WASM
// build from @luau-rs/luau) and luau-lsp's Roblox type definitions.
//
// Studio and luau-lsp understand Roblox-specific constructs that a plain analyzer does not; this
// script emulates them with line-preserving rewrites so reported line numbers stay exact:
//   * instance-path requires   -> string requires, using targets recorded by record_requires.luau
//   * game:GetService("X")     -> cast to X           (Studio infers the service class)
//   * Instance.new("X")        -> cast to X           (Studio infers the created class)
//   * Enum.X in type positions -> EnumX               (the definitions' enum type names)
//   * script                   -> any                 (Studio types it from the DataModel tree)
// The definitions' giant ENUM_LIST type is trimmed to the enums this project uses, because the
// analyzer otherwise reports "code is too complex to typecheck" while loading definitions.
//
// Usage:
//   npm --prefix tools/typecheck install
//   curl -o build/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
//   lune run tools/typecheck/record_requires.luau build/IronThrone.rbxl build/requires.json
//   node tools/typecheck/typecheck.mjs build/requires.json build/globalTypes.d.luau
// Exit code 1 when diagnostics are reported.

import { Analysis } from '@luau-rs/luau/analysis';
import fs from 'node:fs';
import path from 'node:path';

const [requiresPath, definitionsPath] = process.argv.slice(2);
if (!requiresPath || !definitionsPath) {
  console.error('usage: node typecheck.mjs <requires.json> <globalTypes.d.luau>');
  process.exit(2);
}

const data = JSON.parse(fs.readFileSync(requiresPath, 'utf8'));

// Enums referenced anywhere in the project.
const usedEnums = new Set();
for (const script of data.modules) {
  for (const match of script.source.matchAll(/\bEnum\.([A-Za-z0-9]+)/g)) usedEnums.add(match[1]);
}

const defLines = fs.readFileSync(definitionsPath, 'utf8').split('\n');
const enumStart = defLines.findIndex((line) => line.startsWith('type ENUM_LIST = {'));
const enumEnd = defLines.findIndex((line, index) => index > enumStart && line.startsWith('} & { GetEnums'));
if (enumStart < 0 || enumEnd < 0) {
  console.error('could not find ENUM_LIST in the definitions file');
  process.exit(2);
}
const enumEntries = defLines
  .slice(enumStart + 1, enumEnd)
  .filter((line) => usedEnums.has(line.trim().split(':')[0]));
const definitions = [
  ...defLines.slice(0, enumStart),
  'type ENUM_LIST = {',
  ...enumEntries,
  '}',
  ...defLines.slice(enumEnd + 1),
  'declare script: any',
].join('\n');

const toModuleName = (fullName) => fullName.split('.').join('/');
const analysis = await Analysis.create({ mode: 'strict', lint: true, definitions: [{ name: 'roblox', source: definitions }] });

const names = [];
const notes = [];
const rewrittenLocals = new Set(['ReplicatedStorage', 'Controllers', 'SimulationFolder', 'UIFolder', 'App']);

for (const script of data.modules) {
  const moduleName = toModuleName(script.name);
  const lines = script.source.split('\n');

  const targetsByLine = new Map();
  for (const entry of data.requires[`[string "${script.name}"]`] || []) {
    if (!targetsByLine.has(entry.line)) targetsByLine.set(entry.line, new Set());
    targetsByLine.get(entry.line).add(entry.target);
  }
  for (const [line, targets] of targetsByLine) {
    if (targets.size !== 1) {
      notes.push(`${script.name}:${line} requires several modules dynamically; left untyped`);
      continue;
    }
    let relative = path.posix.relative(path.posix.dirname(moduleName), toModuleName([...targets][0]));
    if (!relative.startsWith('.')) relative = './' + relative;
    const text = lines[line - 1];
    const start = text.indexOf('require(');
    if (start < 0) continue;
    let depth = 0;
    let end = start + 'require'.length;
    for (; end < text.length; end++) {
      if (text[end] === '(') depth++;
      else if (text[end] === ')' && --depth === 0) break;
    }
    lines[line - 1] = text.slice(0, start) + `require("${relative}")` + text.slice(end + 1);
  }

  for (let i = 0; i < lines.length; i++) {
    lines[i] = lines[i]
      .replace(/(\w+):GetService\("(\w+)"\)/g, '($1:GetService("$2") :: $2)')
      .replace(/Instance\.new\("(\w+)"\)/g, '(Instance.new("$1") :: $1)')
      .replace(/(:\s*|::\s*|->\s*|\(\s*|\|\s*)Enum\.(\w+)(?![.\w])/g, '$1Enum$2');
  }

  analysis.setModule(moduleName, lines.join('\n'), script.className === 'ModuleScript' ? 'module' : 'script');
  names.push(moduleName);
}

const seen = new Set();
for (const { result } of analysis.checkModules(names)) {
  for (const diagnostic of result.diagnostics) {
    const unused = diagnostic.code === 'LocalUnused' && /Variable '(\w+)'/.exec(diagnostic.message);
    if (unused && rewrittenLocals.has(unused[1])) continue; // only used by a rewritten require
    const key = `${diagnostic.module}:${diagnostic.location.begin.line}:${diagnostic.message}`;
    if (seen.has(key)) continue; // dependencies are re-reported by every dependant
    seen.add(key);
    console.log(`${diagnostic.module}:${diagnostic.location.begin.line + 1}: [${diagnostic.kind} ${diagnostic.code}] ${diagnostic.message}`);
  }
}
for (const note of notes) console.log(`note: ${note}`);
console.log(`type-checked ${names.length} scripts in strict mode: ${seen.size} diagnostic(s)`);
process.exit(seen.size > 0 ? 1 : 0);
