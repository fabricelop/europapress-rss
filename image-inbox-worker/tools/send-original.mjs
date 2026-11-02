import { episodeFingerprint } from '../src/editorial-truth.mjs';
// Opt-in PC importer: never invoked automatically by the existing image consumers.
// Reads existing original PNG only, sends it to a PRIVATE inbox, never edits catalogs.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];

export function validateDestination(raw) {
  const url = new URL(raw);
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password ||
      url.port || url.search || url.hash || !['/', ''].includes(url.pathname)) {
    throw Error('A verified private HTTPS base URL is required');
  }
  return url.origin;
}

export async function prepare(originalBytes, metadata) {
  const raster = new Uint8Array(originalBytes);
  if (raster.length < 24 || raster.length > 10_000_000 ||
      !PNG_SIGNATURE.every((value, index) => raster[index] === value)) {
    throw Error('Use the exact original PNG, not a preview, JPG or edited copy');
  }
  if (!metadata || typeof metadata !== 'object' || !metadata.identity ||
      !['ttittulares','ttendencias'].includes(metadata.identity.project) ||
      typeof metadata.title !== 'string' || !metadata.title.trim() ||
      typeof metadata.editorialText !== 'string' || !metadata.editorialText.trim()) {
    throw Error('Exact target identity, title and factual editorial text are required');
  }
  const hash = createHash('sha256').update(raster).digest('hex');
  if (metadata.identity.rasterSHA256 && metadata.identity.rasterSHA256 !== hash) {
    throw Error('The original PNG does not match the supplied SHA-256');
  }
  const fingerprint = await episodeFingerprint({
    ...metadata.identity, editorialText: metadata.editorialText,
  });
  if (metadata.identity.episodeFingerprint && metadata.identity.episodeFingerprint !== fingerprint) {
    throw Error('Episode fingerprint is not the exact current editorial text');
  }
  const exactMetadata = {
    ...metadata, identity: { ...metadata.identity,
      episodeFingerprint: fingerprint, rasterSHA256: hash },
  };
  const form = new FormData();
  form.set('image', new Blob([raster], { type: 'image/png' }), 'original.png');
  form.set('metadata', JSON.stringify(exactMetadata));
  return { form, rasterSHA256: hash };
}

export async function sendPendingImage({ baseURL, secret, originalBytes, metadata, fetchFn = fetch }) {
  if (typeof secret !== 'string' || secret.length < 32) {
    throw Error('TT_IMAGE_INGEST_TOKEN secret is missing');
  }
  const origin = validateDestination(baseURL);
  const {form, rasterSHA256} = await prepare(originalBytes, metadata);
  const response = await fetchFn(origin + '/v1/images/ingest', {
    method: 'POST', headers: {'X-TT-Ingest-Key': secret}, body: form,
    redirect: 'error', signal: AbortSignal.timeout(30_000),
  });
  if (![200, 201].includes(response.status)) {
    throw Error(`Private inbox rejected the original (HTTP ${response.status})`);
  }
  const receipt = await response.json();
  if (!/^[a-f0-9]{64}$/.test(receipt.id || '') ||
      !['pending','existing'].includes(receipt.state)) {
    throw Error('Invalid private inbox receipt');
  }
  return { id: receipt.id, state: receipt.state, rasterSHA256 };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const image = args[args.indexOf('--image') + 1];
  const info = args[args.indexOf('--metadata') + 1];
  if (!args.includes('--image') || !args.includes('--metadata') || !image || !info) {
    process.stderr.write('Usage: node send-original.mjs --image original.png --metadata metadata.json\n');
    process.exitCode = 2;
  } else {
    try {
      const originalBytes = await readFile(image);
      const metadata = JSON.parse(await readFile(info, 'utf8'));
      const result = await sendPendingImage({
        baseURL: process.env.TT_IMAGE_APPROVAL_ENDPOINT,
        secret: process.env.TT_IMAGE_INGEST_TOKEN, originalBytes, metadata,
      });
      // Only non-sensitive receipt metadata. Never log private URL or secret.
      process.stdout.write(`Private inbox accepted ${result.id} (${result.state})\n`);
    } catch (e) {
      process.stderr.write(`Private inbox ingestion failed: ${e.message}\n`);
      process.exitCode = 1;
    }
  }
}