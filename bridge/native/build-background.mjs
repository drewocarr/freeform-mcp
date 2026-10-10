// Builds bin/freeform-background: the regular helper's declarations plus the background main file.
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const helper = await readFile(new URL('./FreeformBridge.swift', import.meta.url), 'utf8');
const boundary = helper.indexOf('\nvar transaction: ClipboardTransaction?');
if (boundary < 0) throw new Error('Helper declaration boundary missing');
const body = await readFile(new URL('./FreeformBackground.swift', import.meta.url), 'utf8');
const directory = await mkdtemp(join(tmpdir(), 'freeform-background-build-'));
try {
  const source = join(directory, 'main.swift');
  await writeFile(source, helper.slice(0, boundary) + '\n' + body);
  const bin = fileURLToPath(new URL('../bin/', import.meta.url));
  await mkdir(bin, { recursive: true });
  execFileSync('swiftc', [source, '-o', join(bin, 'freeform-background')], { stdio: 'inherit' });
} finally {
  await rm(directory, { recursive: true, force: true });
}
