import { readFile, writeFile } from 'node:fs/promises';
import openapiTS, { astToString, COMMENT_HEADER } from 'openapi-typescript';

const spec = new URL('../../docs/openapi.yaml', import.meta.url);
const target = new URL('../src/lib/api.gen.d.ts', import.meta.url);
const source = COMMENT_HEADER + astToString(await openapiTS(spec));
if (process.argv.includes('--check')) {
  if (await readFile(target, 'utf8') !== source) {
    console.error('generated API is stale; run npm run generate');
    process.exitCode = 1;
  }
} else {
  await writeFile(target, source);
}
