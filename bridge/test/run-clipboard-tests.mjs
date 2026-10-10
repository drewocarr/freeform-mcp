import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const directory = await mkdtemp(join(tmpdir(), 'freeform-clipboard-tests-'));
try {
  const source = await readFile(new URL('../native/FreeformBridge.swift', import.meta.url), 'utf8');
  const boundary = source.indexOf('\nvar transaction: ClipboardTransaction?');
  if (boundary < 0) throw new Error('Helper declaration boundary missing');
  const tests = await readFile(new URL('./clipboard-transaction.swift', import.meta.url), 'utf8');
  const file = join(directory, 'main.swift');
  const binary = join(directory, 'clipboard-tests');
  await writeFile(file, source.slice(0, boundary) + '\n' + tests);
  execFileSync('swiftc', [file, '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
} finally {
  await rm(directory, { recursive: true, force: true });
}
