// The manual, built from the repo's own Markdown. chapters.json says which
// heading ranges of README.md and docs/*.md make up each chapter; this file
// slices them out, numbers the sections, points the links at the right
// chapter, and turns the docs' conventions into the design's components.
// The docs stay plain Markdown that GitHub renders as it always has.

import fs from 'node:fs';
import path from 'node:path';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import remarkRehype from 'remark-rehype';
import rehypeRaw from 'rehype-raw';
import rehypeParse from 'rehype-parse';
import rehypeStringify from 'rehype-stringify';
import GithubSlugger from 'github-slugger';
import { toString as mdText } from 'mdast-util-to-string';
import { toString as hText } from 'hast-util-to-string';
import { visit, SKIP } from 'unist-util-visit';
import { h } from 'hastscript';
import config from '../chapters.json';

export const REPO_ROOT = process.env.REPO_ROOT ?? path.resolve(process.cwd(), '..');

// A screenshot's size in CSS pixels: render-screens.scd draws at 2x, so half
// the PNG's own (its IHDR width and height). Null for anything else.
function shotSize(src: string): { width: number; height: number } | null {
  const at = src.indexOf('docs/images/');
  if (at < 0 || !src.endsWith('.png')) return null;
  try {
    const fd = fs.openSync(path.join(REPO_ROOT, src.slice(at)), 'r');
    const head = Buffer.alloc(24);
    fs.readSync(fd, head, 0, 24, 0);
    fs.closeSync(fd);
    return { width: Math.round(head.readUInt32BE(16) / 2), height: Math.round(head.readUInt32BE(20) / 2) };
  } catch {
    return null;
  }
}
export const GITHUB = 'https://github.com/weltfried/megalooper';
const FIGURES_DIR = path.join(process.cwd(), 'src', 'figures');

export type Layer = 'loop' | 'cut' | 'grain' | 'fx' | 'drum';
export interface ChapterConfig {
  n: number;
  slug: string;
  title: string;
  group: string;
  layer?: Layer;
  rig: 'every' | 'sa' | 'live' | 'linux' | 'macos';
  lead?: string;
  placeholder?: string;
  sources: Source[];
  figures?: { section: string; after?: number; file: string }[];
}
interface Source {
  file: string;
  heading?: string;
  part?: 'intro';
  unwrap?: boolean;
  title?: string;
  introTitle?: string;
}
export interface Section { id: string; number: string; title: string }
export interface RenderedChapter { html: string; lead: string; sections: Section[] }

export const chapters = config.chapters as ChapterConfig[];
export const groups = config.groups as string[];

export function chapterHref(base: string, slug: string) {
  return `${base}manual/${slug}/`;
}

// ---------------------------------------------------------------- parsing

interface Heading { i: number; depth: number; text: string; slug: string }
interface ParsedFile { tree: any; headings: Heading[] }

const parser = unified().use(remarkParse).use(remarkGfm);
const files = new Map<string, ParsedFile>();

function parseFile(file: string): ParsedFile {
  let pf = files.get(file);
  if (pf) return pf;
  const tree: any = parser.runSync(parser.parse(fs.readFileSync(path.join(REPO_ROOT, file), 'utf8')));
  // Slug every heading, nested ones too, in document order: that is how
  // GitHub numbers duplicate anchors, and links in the docs use its anchors.
  const slugger = new GithubSlugger();
  const slugs = new Map<any, string>();
  visit(tree, 'heading', (node: any) => { slugs.set(node, slugger.slug(mdText(node))); });
  const headings: Heading[] = [];
  tree.children.forEach((node: any, i: number) => {
    if (node.type === 'heading') headings.push({ i, depth: node.depth, text: mdText(node).trim(), slug: slugs.get(node)! });
  });
  pf = { tree, headings };
  files.set(file, pf);
  return pf;
}

interface Range { root: Heading | null; depth: number; start: number; introEnd: number; end: number; inner: Heading[] }

function locate(file: string, heading?: string): Range {
  const pf = parseFile(file);
  let root: Heading | null;
  if (!heading) {
    root = pf.headings.find((x) => x.depth === 1) ?? null;
  } else {
    const m = /^(#+)\s+(.*)$/.exec(heading.trim());
    if (!m) throw new Error(`chapters.json: "${heading}" should start with #s`);
    const hits = pf.headings.filter((x) => x.depth === m[1].length && x.text === m[2].trim());
    if (hits.length !== 1) {
      throw new Error(`chapters.json: "${heading}" matches ${hits.length} headings in ${file}, it must match exactly one`);
    }
    root = hits[0];
  }
  const depth = root?.depth ?? 1;
  const start = root ? root.i + 1 : 0;
  const next = pf.headings.find((x) => x.i >= start && x.depth <= depth && root);
  const end = next ? next.i : pf.tree.children.length;
  const inner = pf.headings.filter((x) => x.i >= start && x.i < end);
  return { root, depth, start, introEnd: inner[0]?.i ?? end, end, inner };
}

// ------------------------------------------------------- building chapters

interface Target { slug: string; id: string | null; number: string | null; title: string }
interface Built { cfg: ChapterConfig; tree: any; sections: Section[]; firstFile?: string }

const key = (file: string, slug: string) => `${file}#${slug}`;
const clone = <T>(x: T): T => structuredClone(x);

let built: Map<string, Built> | null = null;
const targets = new Map<string, Target>();

function headingNode(depth: number, children: any[], srcKey?: string) {
  return { type: 'heading', depth, children, data: srcKey ? { srcKey } : {} };
}

function buildChapter(cfg: ChapterConfig): Built {
  const out: any[] = [];
  const topKeys: string[] = [];

  for (const src of cfg.sources) {
    const pf = parseFile(src.file);
    const r = locate(src.file, src.heading);
    const rootKey = r.root ? key(src.file, r.root.slug) : null;
    const intro = clone(pf.tree.children.slice(r.start, r.introEnd));
    const rest = src.part === 'intro' ? [] : clone(pf.tree.children.slice(r.introEnd, r.end));
    if (src.part !== 'intro') {
      for (const x of r.inner) rest[x.i - r.introEnd].data = { ...rest[x.i - r.introEnd].data, srcKey: key(src.file, x.slug) };
    }
    const shift = (by: number) => {
      for (const n of rest) if (n.type === 'heading') n.depth = Math.min(6, Math.max(2, n.depth + by));
    };

    if (src.unwrap) {
      if (intro.length) {
        if (out.length === 0 && !src.introTitle) {
          if (rootKey) topKeys.push(rootKey);
          out.push(...intro);
        } else {
          out.push(headingNode(2, [{ type: 'text', value: src.introTitle ?? r.root?.text ?? cfg.title }], rootKey ?? undefined), ...intro);
        }
      } else if (rootKey) {
        topKeys.push(rootKey);
      }
      shift(1 - r.depth);
      out.push(...rest);
    } else {
      const title = src.title
        ? [{ type: 'text', value: src.title }]
        : r.root
          ? clone(pf.tree.children[r.root.i].children)
          : [{ type: 'text', value: cfg.title }];
      out.push(headingNode(2, title, rootKey ?? undefined), ...intro);
      shift(2 - r.depth);
      out.push(...rest);
    }
  }

  const tree = { type: 'root', children: out };
  const sections: Section[] = [];
  for (const k of topKeys) if (!targets.has(k)) targets.set(k, { slug: cfg.slug, id: null, number: null, title: cfg.title });

  // Number the sections from the headings: 7.1, 7.1.1, then unnumbered.
  const slugger = new GithubSlugger();
  let s2 = 0, s3 = 0, parent = `s${cfg.n}`;
  for (const node of out) {
    if (node.type !== 'heading') continue;
    const text = mdText(node).trim();
    let id: string, number: string | null = null;
    if (node.depth === 2) {
      s2++; s3 = 0;
      id = parent = `s${cfg.n}-${s2}`;
      number = `${cfg.n}.${s2}`;
      sections.push({ id, number, title: text });
    } else if (node.depth === 3) {
      s3++;
      id = `s${cfg.n}-${s2}-${s3}`;
      number = `${cfg.n}.${s2}.${s3}`;
    } else {
      id = `${parent}-${slugger.slug(text)}`;
    }
    node.data = { ...node.data, hProperties: { id, dataNumber: number ?? undefined } };
    if (node.depth <= 3) parent = id;
    const k = node.data.srcKey;
    if (k && !targets.has(k)) targets.set(k, { slug: cfg.slug, id, number, title: text });
  }

  return { cfg, tree, sections, firstFile: cfg.sources[0]?.file };
}

function buildAll(): Map<string, Built> {
  if (built) return built;
  built = new Map();
  for (const cfg of chapters) built.set(cfg.slug, buildChapter(cfg));
  reportCoverage();
  return built;
}

// ------------------------------------------------------------------ links

function fileHome(file: string): string | null {
  const homes = config.fileHomes as Record<string, string>;
  if (homes[file]) return homes[file];
  const whole = chapters.find((c) => c.sources.some((s) => s.file === file && !s.heading && s.part !== 'intro'));
  if (whole) return whole.slug;
  return chapters.find((c) => c.sources.some((s) => s.file === file))?.slug ?? null;
}

function resolveLink(url: string, fromFile: string, base: string): { url: string; target?: Target } {
  if (/^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith('//')) return { url };
  const [p, hash] = url.split('#') as [string, string | undefined];
  const file = p ? path.posix.normalize(path.posix.join(path.posix.dirname(fromFile), p)) : fromFile;
  if (file.endsWith('.md') && fs.existsSync(path.join(REPO_ROOT, file)) && !file.startsWith('docs/dev/')) {
    if (hash) {
      const t = targets.get(key(file, hash));
      if (t) return { url: chapterHref(base, t.slug) + (t.id ? `#${t.id}` : ''), target: t };
      return { url: `${GITHUB}/blob/main/${file}#${hash}` };
    }
    // A whole file that became a section of a chapter: that section.
    const h1 = parseFile(file).headings.find((x) => x.depth === 1);
    const placed = h1 && targets.get(key(file, h1.slug));
    if (placed?.id && !(config.fileHomes as Record<string, string>)[file]) {
      return { url: chapterHref(base, placed.slug) + `#${placed.id}`, target: placed };
    }
    const home = fileHome(file);
    if (home) {
      const c = chapters.find((x) => x.slug === home)!;
      return { url: chapterHref(base, home), target: { slug: home, id: null, number: null, title: c.title } };
    }
  }
  let isDir = false;
  try { isDir = fs.statSync(path.join(REPO_ROOT, file)).isDirectory(); } catch { /* not in the repo */ }
  return { url: `${GITHUB}/${isDir ? 'tree' : 'blob'}/main/${file}${hash ? `#${hash}` : ''}` };
}

// Which file each node came from, so relative links resolve against it.
function linkPass(tree: any, cfg: ChapterConfig, base: string) {
  // Nodes carry their source position only, not the file, so walk the
  // sources again in step with the output: every link in a chapter comes
  // from one of its sources, and positions are unique per file.
  const posFile = new Map<string, string>();
  for (const src of cfg.sources) {
    visit(parseFile(src.file).tree, 'link', (n: any) => {
      if (n.position) posFile.set(`${n.position.start.offset}:${n.url}`, src.file);
    });
  }
  // Images in docs/images/ are served at docs/images/ beside the manual.
  visit(tree, 'image', (n: any) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(n.url) || n.url.startsWith('/')) return;
    const from = cfg.sources.find((s) => fs.existsSync(path.join(REPO_ROOT, path.posix.dirname(s.file), n.url)))?.file;
    if (!from) return;
    const file = path.posix.normalize(path.posix.join(path.posix.dirname(from), n.url));
    if (file.startsWith('docs/images/')) n.url = `${base}${file}`;
  });
  visit(tree, 'link', (n: any) => {
    const from = (n.position && posFile.get(`${n.position.start.offset}:${n.url}`)) ?? cfg.sources[0]?.file ?? 'README.md';
    const { url, target } = resolveLink(n.url, from, base);
    n.url = url;
    if (!target || n.children.length !== 1 || n.children[0].type !== 'text') return;
    const t = n.children[0];
    if (/\.md(#.*)?$/.test(t.value)) {
      t.value = target.number ? `${target.number} ${target.title}` : target.title;
    } else if (target.number && t.value.trim() === target.title) {
      t.value = `${target.number} ${t.value}`;
    }
  });
}

// --------------------------------------------------- components (on hast)

const isEl = (n: any, tag?: string) => n?.type === 'element' && (!tag || n.tagName === tag);
const isWs = (n: any) => n?.type === 'text' && !n.value.trim();
const elements = (n: any) => (n.children ?? []).filter((c: any) => c.type === 'element');
const addClass = (n: any, c: string) => {
  const cur = n.properties.className ?? [];
  n.properties.className = [...(Array.isArray(cur) ? cur : [cur]), c];
};

const VIEWS: Record<string, number> = { perform: 1, sound: 2, fx: 3, drums: 4, setup: 5, calibrate: 6, synth: 7 };
const MIDI_TEXT = /^(Program Change|PC|CC|Note On|NOTE|Note)\s+(\d+(?:\s*[–-]\s*\d+)?(?:,\s*\d+)*)(\s+on channel\s+\d+|\s*·\s*CH\s*\d+)?$/;

function midiLabel(text: string): string | null {
  const m = MIDI_TEXT.exec(text.trim());
  if (!m) return null;
  const kind = { 'Program Change': 'PC', PC: 'PC', CC: 'CC', 'Note On': 'NOTE', Note: 'NOTE', NOTE: 'NOTE' }[m[1]]!;
  const ch = m[3] ? ` · CH ${m[3].replace(/\D+/g, '')}` : '';
  return `${kind} ${m[2]}${ch}`;
}

function viewTag(name: string, num?: string, small = false) {
  const n = num ?? VIEWS[name.toLowerCase()];
  return h('span', { className: ['viewtag', ...(small ? ['viewtag--sm'] : [])] }, n ? `${name.toUpperCase()} · ${n}` : name.toUpperCase());
}

function inlineCode(node: any) {
  const t = hText(node);
  const midi = /^(PC|CC|NOTE) \d+/.test(t);
  if (midi) return h('span', { className: ['midi'] }, t);
  if (/^[A-Z]$/.test(t) || /^(Cmd|Ctrl|Shift|Alt|Opt|Option|Esc|Tab|Return|Space)(\+.+)?$/.test(t)) return h('kbd', t);
  if (/^[●▶■]?\s?[A-Z][A-Z0-9 ·→/@.?:+…'-]*$/.test(t) && (t.includes('·') || /^[●▶■]/.test(t))) return h('span', { className: ['status'] }, t);
  return null;
}

function codeBlock(pre: any) {
  const code = elements(pre)[0];
  if (!code || code.children.length !== 1 || code.children[0].type !== 'text') return;
  const cls: string[] = code.properties.className ?? [];
  const lang = (cls.find((c) => c.startsWith('language-')) ?? '').slice(9);
  const shell = ['', 'bash', 'sh', 'shell', 'zsh', 'console'].includes(lang);
  const sc = ['supercollider', 'sc', 'sclang'].includes(lang);
  if (!shell && !sc) return;
  const out: any[] = [];
  const lines = code.children[0].value.split('\n');
  lines.forEach((line: string, i: number) => {
    let rest = line;
    if (shell && /^\$ /.test(rest)) { out.push(h('span', { className: ['mute'] }, '$')); rest = rest.slice(1); }
    const at = shell ? rest.search(/(^|\s)#/) : rest.indexOf('//');
    if (at >= 0 && lang !== '') {
      const cut = shell && rest[at] !== '#' ? at + 1 : at;
      out.push({ type: 'text', value: rest.slice(0, cut) }, h('span', { className: ['mute'] }, rest.slice(cut)));
    } else {
      out.push({ type: 'text', value: rest });
    }
    if (i < lines.length - 1) out.push({ type: 'text', value: '\n' });
  });
  code.children = out;
}

// A list whose every item reads "**Name** *(View)* — what it does" is a
// control reference, drawn as a definition list.
function controlRef(ul: any): any | null {
  const items = elements(ul).filter((li: any) => li.tagName === 'li');
  if (items.length < 2) return null;
  const rows: any[] = [];
  for (const li of items) {
    const kids = li.children.filter((c: any) => !isWs(c));
    const head = isEl(kids[0], 'p') ? kids[0] : null;
    const inline = head ? head.children : li.children;
    const after = head ? kids.slice(1) : [];
    let i = 0;
    while (isWs(inline[i])) i++;
    if (!isEl(inline[i], 'strong')) return null;
    const name = inline[i++];
    let view: any = null;
    if (isWs(inline[i]) && isEl(inline[i + 1], 'em') && /^\(.*\)$/.test(hText(inline[i + 1]).trim())) {
      view = hText(inline[i + 1]).trim().slice(1, -1);
      i += 2;
    }
    const sep = inline[i];
    if (sep?.type !== 'text' || !/^\s*[—–:]\s/.test(sep.value)) return null;
    const restInline = [{ type: 'text', value: sep.value.replace(/^\s*[—–:]\s*/, '') }, ...inline.slice(i + 1)];
    const blocksAfter = head ? after : [];
    if (!head) {
      // a tight item: inline nodes then maybe a nested list
      const firstBlock = restInline.findIndex((n: any) => isEl(n) && ['ul', 'ol', 'p', 'pre', 'table'].includes(n.tagName));
      if (firstBlock >= 0) blocksAfter.push(...restInline.splice(firstBlock));
    }
    const dt = h('dt', [h('b', name.children)]);
    if (view) {
      const m = /^(\w+)(?:'s|\s*›)?\s*(.*)$/.exec(view)!;
      if (VIEWS[m[1].toLowerCase()]) {
        dt.children.push(viewTag(m[1], undefined, true));
        if (m[2]) dt.children.push(h('span', { className: ['dt-detail'] }, m[2]));
      } else {
        dt.children.push(h('span', { className: ['viewtag', 'viewtag--sm'] }, view.toUpperCase()));
      }
    }
    rows.push(h('div', { className: ['ref__row'] }, [dt, h('dd', [h('p', restInline), ...blocksAfter])]));
  }
  return h('dl', { className: ['ref'] }, rows);
}

function callout(bq: any) {
  const kids = elements(bq);
  const p = kids[0];
  let kind = 'note', label = 'NOTE';
  const first = p?.children?.[0];
  if (isEl(p, 'p') && first?.type === 'text' && /^\[!(NOTE|TIP|WARNING|CAUTION|IMPORTANT)\]/.test(first.value)) {
    const m = /^\[!(\w+)\]\s*/.exec(first.value)!;
    first.value = first.value.slice(m[0].length);
    if (isEl(p.children[1], 'br')) p.children.splice(1, 1);
    const k = m[1];
    if (k === 'TIP') { kind = 'tip'; label = 'TIP'; }
    else if (k === 'WARNING' || k === 'CAUTION') {
      kind = 'warn';
      const s = p.children.find((c: any) => !isWs(c) && !(c.type === 'text' && !c.value));
      label = isEl(s, 'strong') && /^Refused when/i.test(hText(s)) ? 'REFUSED WHEN' : 'CAUTION';
    } else { kind = 'stage'; label = 'ON STAGE'; }
    if (!first.value) p.children.shift();
  } else if (isEl(p, 'p') && isEl(first, 'strong')) {
    const lead = hText(first).trim();
    if (/^(Changed|Moved|Renamed|Added|Removed)\b.*\d{4}-\d{2}-\d{2}/.test(lead)) {
      kind = 'changed';
      label = lead.replace(/[.,:;]+$/, '').toUpperCase();
      p.children.shift();
      const t = p.children[0];
      if (t?.type === 'text') {
        t.value = t.value.replace(/^[\s,.;:—–-]+/, '');
        t.value = t.value.charAt(0).toUpperCase() + t.value.slice(1);
      }
    } else if (/^Why\b/.test(lead)) {
      kind = 'changed'; label = 'WHY';
    }
  }
  return h('aside', { className: ['callout', `callout--${kind}`] }, [
    h('div', { className: ['callout__bar'] }),
    h('div', { className: ['callout__body'] }, [h('div', { className: ['callout__label'] }, label), ...bq.children]),
  ]);
}

function components(tree: any) {
  visit(tree, 'element', (node: any, index: number | undefined, parent: any) => {
    if (!parent || index === undefined) return;
    const tag = node.tagName;

    if (tag === 'pre') { codeBlock(node); return SKIP; }

    if (tag === 'code') {
      const r = inlineCode(node);
      if (r) { parent.children[index] = r; return SKIP; }
      return;
    }

    if (tag === 'table') {
      const heads = (elements(elements(node).find((x: any) => x.tagName === 'thead') ?? { children: [] })[0]?.children ?? [])
        .filter((x: any) => isEl(x)).map((th: any) => hText(th).trim().toLowerCase());
      visit(node, 'element', (td: any) => {
        if (td.tagName !== 'td') return;
        const kids = td.children.filter((c: any) => !isWs(c));
        if (kids.length !== 1 || kids[0].type !== 'text') return;
        const midi = midiLabel(kids[0].value);
        if (midi) td.children = [h('span', { className: ['midi'] }, midi)];
      });
      // A "Key" column's code is a key.
      const keyCol = heads.indexOf('key');
      if (keyCol >= 0) {
        visit(node, 'element', (tr: any) => {
          if (tr.tagName !== 'tr') return;
          const td = elements(tr)[keyCol];
          if (td?.tagName === 'td') visit(td, 'element', (c: any, i: number | undefined, p: any) => {
            if (c.tagName === 'code' && p && i !== undefined) p.children[i] = h('kbd', hText(c));
          });
        });
      }
      parent.children[index] = h('div', { className: ['table-wrap'] }, [node]);
      return SKIP;
    }

    if (tag === 'p') {
      // Figure: an image alone in a paragraph, then "*Fig: caption*".
      const kids = node.children.filter((c: any) => !isWs(c));
      if (kids.length === 1 && isEl(kids[0], 'img')) {
        let j = index + 1;
        while (isWs(parent.children[j])) j++;
        const cap = parent.children[j];
        const em = cap && isEl(cap, 'p') ? cap.children.find((c: any) => !isWs(c)) : null;
        if (em && isEl(em, 'em') && /^Fig:/.test(hText(em))) {
          const first = em.children[0];
          if (first?.type === 'text') first.value = first.value.replace(/^Fig:\s*/, '');
          parent.children.splice(j, 1);
          // A screenshot shows at its own size, shrunk to the article's width
          // when it is wider: a click opens it at full size.
          const img = kids[0];
          const size = shotSize(String(img.properties.src ?? ''));
          if (size) Object.assign(img.properties, size);
          img.properties.loading = 'lazy';
          img.properties.decoding = 'async';
          parent.children[index] = h('figure', { className: ['fig'] }, [
            h('div', { className: ['fig__body', 'fig__body--img'] }, [
              h('a', { href: img.properties.src, title: 'Open at full size' }, [img]),
            ]),
            h('figcaption', em.children),
          ]);
          return SKIP;
        }
      }
    }
  });

  // View tags written as [[Setup 5]] or {view:setup}, outside code.
  visit(tree, 'text', (node: any, index: number | undefined, parent: any) => {
    if (!parent || index === undefined || ['code', 'pre', 'kbd'].includes(parent.tagName)) return;
    const re = /\[\[([A-Za-z]+)\s*(\d)?\]\]|\{view:([a-z]+)\}/g;
    if (!re.test(node.value)) return;
    re.lastIndex = 0;
    const out: any[] = [];
    let last = 0, m: RegExpExecArray | null;
    while ((m = re.exec(node.value))) {
      out.push({ type: 'text', value: node.value.slice(last, m.index) });
      const name = m[1] ?? m[3];
      out.push(viewTag(name, m[2]));
      last = m.index + m[0].length;
    }
    out.push({ type: 'text', value: node.value.slice(last) });
    parent.children.splice(index, 1, ...out);
    return index + out.length;
  });

  // The structural ones last, once everything inside them is converted:
  // they rebuild their children into new elements.
  visit(tree, 'element', (node: any, index: number | undefined, parent: any) => {
    if (!parent || index === undefined || node.tagName !== 'ul') return;
    const dl = controlRef(node);
    if (dl) { parent.children[index] = dl; return SKIP; }
  });
  visit(tree, 'element', (node: any, index: number | undefined, parent: any) => {
    if (!parent || index === undefined || node.tagName !== 'blockquote') return;
    parent.children[index] = callout(node);
    return SKIP;
  });
}

// Wrap the top level into the intro and one <section> per H2; number
// headings and figures; mark the lead, steps and injected figures.
function sectionize(tree: any, b: Built): any {
  const { cfg } = b;
  const intro: any[] = [];
  const sections: any[] = [];
  let cur: any = null;
  for (const node of tree.children) {
    if (isWs(node)) continue;
    if (isEl(node) && /^h[2-6]$/.test(node.tagName)) {
      const num = node.properties.dataNumber;
      delete node.properties.dataNumber;
      if (num) node.children.unshift(h('span', { className: ['num'] }, String(num)));
      if (node.tagName === 'h2') {
        // The id stays on the heading, where Pagefind looks for anchors.
        cur = h('section', { className: ['sec'], ariaLabelledBy: node.properties.id }, [node]);
        sections.push(cur);
        continue;
      }
    }
    if (isEl(node, 'ol')) {
      addClass(node, 'steps');
      for (const li of elements(node)) li.children = [h('div', li.children)];
    }
    (cur ? cur.children : intro).push(node);
  }

  // The lead goes in the chapter header, above its rule.
  let lead: any = null;
  if (cfg.lead || cfg.placeholder) {
    lead = h('p', { className: ['lead'] }, cfg.lead ?? cfg.placeholder!);
  } else if (isEl(intro[0], 'p')) {
    lead = intro.shift();
    addClass(lead, 'lead');
  }

  for (const f of cfg.figures ?? []) {
    const sec = sections.find((s: any) => hText(elements(s)[0]).replace(/^[\d.]+/, '').trim() === f.section);
    if (!sec) throw new Error(`chapters.json: chapter ${cfg.n} has no section "${f.section}" for ${f.file}`);
    const frag: any = unified().use(rehypeParse, { fragment: true }).parse(fs.readFileSync(path.join(FIGURES_DIR, f.file), 'utf8'));
    const nodes = frag.children.filter((n: any) => !isWs(n) && n.type !== 'comment');
    const blocks = sec.children.map((n: any, i: number) => (isEl(n) ? i : -1)).filter((i: number) => i > 0);
    const at = f.after === undefined || f.after >= blocks.length ? sec.children.length : blocks[f.after] ?? sec.children.length;
    sec.children.splice(at, 0, ...nodes);
  }

  const children = [...(intro.length ? [h('div', { className: ['intro'] }, intro)] : []), ...sections];
  let fig = 0;
  visit({ type: 'root', children }, 'element', (node: any) => {
    if (node.tagName !== 'figure') return;
    fig++;
    node.properties.id = `fig-${cfg.n}-${fig}`;
    const cap = elements(node).find((x: any) => x.tagName === 'figcaption');
    if (cap) cap.children = [h('b', `FIG ${cfg.n}.${fig}`), h('span', cap.children)];
    return SKIP;
  });
  tree.children = children;
  return lead;
}

const toHast = unified().use(remarkRehype, { allowDangerousHtml: true }).use(rehypeRaw);
const toHtml = unified().use(rehypeStringify);
const rendered = new Map<string, RenderedChapter>();

export function renderChapter(slug: string, base: string): RenderedChapter {
  const cached = rendered.get(slug);
  if (cached) return cached;
  const b = buildAll().get(slug);
  if (!b) throw new Error(`no chapter ${slug}`);
  const mdast = clone(b.tree);
  linkPass(mdast, b.cfg, base);
  const hast: any = toHast.runSync(mdast);
  components(hast);
  const lead = sectionize(hast, b);
  const out = {
    html: toHtml.stringify(hast),
    lead: lead ? toHtml.stringify({ type: 'root', children: [lead] } as any) : '',
    sections: b.sections,
  };
  rendered.set(slug, out);
  return out;
}

export function sourceNote(cfg: ChapterConfig): { file: string; heading: string | null } | null {
  const s = cfg.sources[0];
  if (!s) return null;
  const heading = s.heading ? s.heading.replace(/^#+\s*/, '') : null;
  return { file: s.file, heading };
}

// --------------------------------------------------------------- coverage

// Warn about any part of the docs no chapter uses, so a new section in
// docs/*.md can't silently miss the website.
function reportCoverage() {
  const docs = ['README.md', ...fs.readdirSync(path.join(REPO_ROOT, 'docs')).filter((f) => f.endsWith('.md')).map((f) => `docs/${f}`)];
  const all = [...chapters.flatMap((c) => c.sources), ...(config.omit as Source[])];
  const missing: string[] = [];
  for (const file of docs) {
    const pf = parseFile(file);
    const used = all.filter((s) => s.file === file).map((s) => ({ intro: s.part === 'intro', r: locate(file, s.heading) }));
    const pos = (r: Range) => (r.root ? r.root.i : -1);
    const unique = pf.headings.filter((x) => x.depth > 1 && pf.headings.filter((y) => y.depth === x.depth && y.text === x.text).length === 1);
    const ranges = [locate(file), ...unique.map((x) => locate(file, `${'#'.repeat(x.depth)} ${x.text}`))];
    for (const r of ranges) {
      if (r.introEnd <= r.start) continue; // nothing of its own to lose
      const p = pos(r);
      const covered = used.some(({ intro, r: q }) => (intro ? pos(q) === p : p >= pos(q) && (p < q.end || !q.root)));
      if (!covered) missing.push(`${file} ${r.root && r.root.depth > 1 ? `${'#'.repeat(r.root.depth)} ${r.root.text}` : '(intro)'}`);
    }
  }
  if (missing.length) {
    console.warn(`\n[manual] ${missing.length} part(s) of the docs are in no chapter (add them to src/chapters.json, or to "omit"):\n  ${missing.join('\n  ')}\n`);
  }
}
