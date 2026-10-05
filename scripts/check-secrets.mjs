import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const rules = [
  ['OpenAI key', /\bsk-(?:(?:proj|svcacct)-)?[A-Za-z0-9_-]{20,}/],
  ['Private signing key', /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/],
];
const paths = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
let failures = 0;
for (const path of paths) {
  if (/(?:^|\/)\.env(?:\.|$)|\.(?:p12|mobileprovision)$/.test(path)) {
    console.error(`Secret file tracked: ${path}`); failures++; continue;
  }
  const source = readFileSync(path, 'utf8');
  for (const [name, pattern] of rules) {
    if (pattern.test(source)) { console.error(`${name} found in tracked file: ${path}`); failures++; }
  }
}
if (failures) process.exit(1);
console.log(`Secret scan passed: ${paths.length} tracked files; matched values are never printed.`);
