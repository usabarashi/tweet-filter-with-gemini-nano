import { build } from 'vite';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, rmSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const outdir = resolve(__dirname, 'dist');
const nodeEnv = process.env.NODE_ENV || 'production';
const isDev = nodeEnv === 'development';

// Build entries: each maps a PureScript module to a Chrome extension component
const entries = [
  {
    name: 'background',
    entry: resolve(__dirname, 'src/entries/background.js'),
    outDir: resolve(outdir, 'background'),
    format: 'es',
  },
  {
    name: 'offscreen',
    entry: resolve(__dirname, 'src/entries/offscreen.js'),
    outDir: resolve(outdir, 'offscreen'),
    format: 'iife',
    globalName: 'TweetFilterOffscreen',
  },
  {
    name: 'content',
    entry: resolve(__dirname, 'src/entries/content.js'),
    outDir: resolve(outdir, 'content'),
    format: 'iife',
    globalName: 'TweetFilterContent',
  },
  {
    name: 'options',
    entry: resolve(__dirname, 'src/entries/options.js'),
    outDir: resolve(outdir, 'options'),
    format: 'iife',
    globalName: 'TweetFilterOptions',
  },
];

try {
  // Clean dist directory
  rmSync(outdir, { recursive: true, force: true });

  // Build each entry point with Vite
  for (const { name, entry, outDir, format, globalName } of entries) {
    await build({
      configFile: false,
      publicDir: false,
      build: {
        lib: {
          entry,
          formats: [format],
          fileName: () => 'index.js',
          ...(globalName ? { name: globalName } : {}),
        },
        outDir,
        emptyOutDir: true,
        target: 'chrome131',
        minify: !isDev,
        sourcemap: isDev,
      },
      resolve: {
        alias: {
          '~ps': resolve(__dirname, 'output'),
        },
      },
      logLevel: 'warn',
    });

    console.log(`  built ${name} (${format})`);
  }

  // Copy static assets
  mkdirSync(resolve(outdir, 'offscreen'), { recursive: true });
  mkdirSync(resolve(outdir, 'options'), { recursive: true });
  mkdirSync(resolve(outdir, 'content'), { recursive: true });

  // manifest.json
  copyFileSync(
    resolve(__dirname, 'public/manifest.json'),
    resolve(outdir, 'manifest.json')
  );

  // Offscreen HTML
  copyFileSync(
    resolve(__dirname, 'src/offscreen/index.html'),
    resolve(outdir, 'offscreen/index.html')
  );

  // Options HTML (update script reference from .ts to .js)
  let optionsHtml = readFileSync(resolve(__dirname, 'src/options/index.html'), 'utf-8');
  optionsHtml = optionsHtml.replace(/src\s*=\s*["']index\.ts["']/, 'src="index.js"');
  writeFileSync(resolve(outdir, 'options/index.html'), optionsHtml);

  // Options CSS
  copyFileSync(
    resolve(__dirname, 'src/options/styles.css'),
    resolve(outdir, 'options/styles.css')
  );

  // Content CSS
  copyFileSync(
    resolve(__dirname, 'src/content/styles.css'),
    resolve(outdir, 'content/index.css')
  );

  console.log('Build completed successfully');
} catch (error) {
  console.error('Build failed:', error);
  process.exit(1);
}
