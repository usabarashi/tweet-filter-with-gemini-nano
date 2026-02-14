import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, rmSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const outdir = resolve(__dirname, 'dist');
const nodeEnv = process.env.NODE_ENV || 'production';

// Path configuration
const paths = {
  background: {
    entry: 'src/background/index.ts',
    outDir: 'dist/background',
    outJs: 'dist/background/index.js',
  },
  offscreen: {
    entry: 'src/offscreen/index.ts',
    outDir: 'dist/offscreen',
    outJs: 'dist/offscreen/index.js',
    srcHtml: 'src/offscreen/index.html',
    outHtml: 'dist/offscreen/index.html',
  },
  content: {
    entry: 'src/content/index.ts',
    outDir: 'dist/content',
    outJs: 'dist/content/index.js',
    srcCss: 'src/content/styles.css',
    outCss: 'dist/content/index.css',
  },
  options: {
    entry: 'src/options/index.ts',
    outDir: 'dist/options',
    outJs: 'dist/options/index.js',
    srcHtml: 'src/options/index.html',
    outHtml: 'dist/options/index.html',
    srcCss: 'src/options/styles.css',
    outCss: 'dist/options/styles.css',
  },
  manifest: {
    src: 'public/manifest.json',
    out: 'dist/manifest.json',
  },
};

try {
  // Clean dist directory and create subdirectories
  rmSync(outdir, { recursive: true, force: true });
  mkdirSync(paths.background.outDir, { recursive: true });
  mkdirSync(paths.offscreen.outDir, { recursive: true });
  mkdirSync(paths.content.outDir, { recursive: true });
  mkdirSync(paths.options.outDir, { recursive: true });

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

  // Parallel builds for all scripts
  await Promise.all([
    // Build background service worker
    esbuild.build({
      entryPoints: [paths.background.entry],
      bundle: true,
      outfile: paths.background.outJs,
      format: 'esm', // ES modules for service worker
      ...buildConfig,
    }),
    // Build offscreen document script
    esbuild.build({
      entryPoints: [paths.offscreen.entry],
      bundle: true,
      outfile: paths.offscreen.outJs,
      format: 'iife', // IIFE for window context
      ...buildConfig,
    }),
    // Build content script
    esbuild.build({
      entryPoints: [paths.content.entry],
      bundle: true,
      outfile: paths.content.outJs,
      format: 'iife',
      ...buildConfig,
    }),
    // Build options page script
    esbuild.build({
      entryPoints: [paths.options.entry],
      bundle: true,
      outfile: paths.options.outJs,
      format: 'iife',
      ...buildConfig,
    }),
  ]);

  // Copy offscreen HTML
  copyFileSync(
    resolve(__dirname, paths.offscreen.srcHtml),
    paths.offscreen.outHtml
  );

  // Copy content script CSS
  copyFileSync(
    resolve(__dirname, paths.content.srcCss),
    paths.content.outCss
  );

  // Process and copy options HTML file (update script reference)
  let html = readFileSync(resolve(__dirname, paths.options.srcHtml), 'utf-8');
  html = html.replace(/src\s*=\s*["']index\.ts["']/, 'src="index.js"');
  writeFileSync(paths.options.outHtml, html);

  // Copy options CSS file
  copyFileSync(
    resolve(__dirname, paths.options.srcCss),
    paths.options.outCss
  );

  // Copy manifest.json (already uses correct paths)
  copyFileSync(
    resolve(__dirname, paths.manifest.src),
    paths.manifest.out
  );

  console.log('✓ Build completed successfully');
} catch (error) {
  console.error('✗ Build failed:', error);
  process.exit(1);
}
