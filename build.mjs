import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, rmSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const outdir = resolve(__dirname, 'dist');
const nodeEnv = process.env.NODE_ENV || 'production';

// Clean and create dist directory
rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });
mkdirSync(resolve(outdir, 'content'), { recursive: true });
mkdirSync(resolve(outdir, 'options'), { recursive: true });

// Build configuration
const buildConfig = {
  platform: 'browser',
  target: 'chrome131',
  sourcemap: nodeEnv === 'development',
  minify: nodeEnv === 'production',
  treeShaking: true,
  define: {
    'process.env.NODE_ENV': JSON.stringify(nodeEnv)
  }
};

// Parallel builds for content script and options page
await Promise.all([
  // Build content script
  esbuild.build({
    entryPoints: ['src/content/index.ts'],
    bundle: true,
    outfile: 'dist/content/index.js',
    format: 'iife',
    ...buildConfig,
  }),
  // Build options page script
  esbuild.build({
    entryPoints: ['src/options/index.ts'],
    bundle: true,
    outfile: 'dist/options/index.js',
    format: 'iife',
    ...buildConfig,
  }),
]);

// Process and copy HTML file (update script reference)
let html = readFileSync(resolve(__dirname, 'src/options/index.html'), 'utf-8');
html = html.replace('src="index.ts"', 'src="index.js"');
writeFileSync(resolve(outdir, 'options/index.html'), html);

// Copy CSS file
copyFileSync(
  resolve(__dirname, 'src/options/styles.css'),
  resolve(outdir, 'options/styles.css')
);

// Update manifest.json to use built files
const manifestPath = resolve(__dirname, 'public/manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));

// Update file references to point to built JS and CSS files
manifest.content_scripts[0].js = ['content/index.js'];
manifest.content_scripts[0].css = ['content/index.css'];
manifest.options_page = 'options/index.html';

writeFileSync(
  resolve(outdir, 'manifest.json'),
  JSON.stringify(manifest, null, 2)
);

console.log('✓ Build completed successfully');
