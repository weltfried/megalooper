// The docs' images (docs/images/), served beside the manual so a figure in
// the Markdown shows on the site as it does on GitHub.
import fs from 'node:fs';
import path from 'node:path';
import type { APIRoute } from 'astro';
import { REPO_ROOT } from '../../../lib/manual';

const DIR = path.join(REPO_ROOT, 'docs', 'images');
const TYPES: Record<string, string> = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp' };

export function getStaticPaths() {
  if (!fs.existsSync(DIR)) return [];
  return fs.readdirSync(DIR).filter((f) => TYPES[path.extname(f).toLowerCase()]).map((file) => ({ params: { file } }));
}

export const GET: APIRoute = ({ params }) => {
  const file = path.join(DIR, path.basename(String(params.file)));
  return new Response(fs.readFileSync(file), { headers: { 'Content-Type': TYPES[path.extname(file).toLowerCase()] } });
};
