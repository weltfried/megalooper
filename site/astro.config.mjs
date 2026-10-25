// @ts-check
import { defineConfig } from 'astro/config';

// Served from GitHub Pages at weltfried.github.io/megalooper/. For a custom
// domain at its root, build with SITE_BASE=/ and SITE_URL=https://the.domain
// (the Pages workflow passes the repository variables of those names). An
// empty value counts as unset.
export default defineConfig({
  site: process.env.SITE_URL || 'https://weltfried.github.io',
  base: process.env.SITE_BASE || '/megalooper/',
  trailingSlash: 'ignore',
  build: { format: 'directory' },
  devToolbar: { enabled: false },
});
