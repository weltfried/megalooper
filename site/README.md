# megalooper's website

The homepage and the manual, built with [Astro](https://astro.build) and
searched with [Pagefind](https://pagefind.app). The manual is generated from
the repo's own `README.md` and `docs/*.md`, which stay the single source of
truth and keep rendering on GitHub as before.

```bash
cd site
npm install
npm run dev        # http://localhost:4321/megalooper/ (search needs a build)
npm run build      # dist/, then the Pagefind index
npm run preview
```

## How the manual is made

`src/chapters.json` lists the 22 chapters and which heading ranges of which
files make up each one. The build:

- slices those ranges out and numbers their headings (7.1, 7.1.1);
- points every link between the docs at the chapter and section it landed in,
  prefixing the section number when the link text is the section's title;
  links to other repo files go to GitHub;
- warns, at build time, about any part of the docs that no chapter uses
  (`[manual] … are in no chapter`), so a new section can't silently miss the
  site. Leave things out on purpose with `omit`.

What the docs already write turns into the design's components:

| In the Markdown | On the page |
|---|---|
| `` `R` ``, `` `Cmd+M` ``, `<kbd>R</kbd>` | a key |
| `` `PC 7` ``, a table cell reading `Program Change 7` or `CC 11` | a MIDI chip |
| `` `TAKE · ANCHORED` ``, `` `● REC` `` | status text |
| `[[Setup 5]]`, `{view:setup}` | a view tag |
| `> [!NOTE]` / `[!TIP]` / `[!WARNING]` | On stage / Tip / Caution (Refused when, if it starts so) |
| `> **Changed on 2026-10-08** …`, `> **Why …**` | a change note |
| any other blockquote | a Note |
| a list of `**Name** *(Setup › Rig)* — …` items | a control reference |
| an ordered list | numbered steps |
| an image alone, then `*Fig: caption*` | a numbered figure |

Drawn figures that GitHub couldn't show live in `src/figures/` and are placed
by `figures` in chapters.json.

## Fonts and screenshots

- **Fonts.** IBM Plex Sans and IBM Plex Mono, in `src/fonts/` with their
  licence (SIL Open Font License). They stand in for the app's Nitti Grotesk
  and Nitti, which are commercial and have no web licence. They are the
  complete files, not a Latin subset, because the manual uses arrows and
  maths signs.
- **Screenshots.** `scripts/render-screens.scd` renders every view of the
  window into `docs/images/` (quit a running megalooper first). The docs
  show them as figures, and the homepage uses `perform.png`.

## Deploying

`.github/workflows/site.yml` builds and publishes to GitHub Pages on every
push to main that touches the site or the docs. The site is built for
`weltfried.github.io/megalooper/`. For a domain of your own, set the
repository variables `SITE_URL=https://the.domain` and `SITE_BASE=/`, add the
domain under Settings → Pages, and run the workflow again; the comment at the
top of the workflow has the steps.
