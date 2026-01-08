import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, rmSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const outdir = resolve(__dirname, 'dist');
const nodeEnv = process.env.NODE_ENV || 'production';

// Path configuration
const paths = {
  content: {
    entry: 'src/content/index.ts',
    outDir: 'dist/content',
    outJs: 'dist/content/index.js',
    outCss: 'content/index.css', // Referenced in manifest.json
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

  // Parallel builds for content script and options page
  await Promise.all([
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

  // Process and copy HTML file (update script reference)
  let html = readFileSync(resolve(__dirname, paths.options.srcHtml), 'utf-8');
  html = html.replace('src="index.ts"', 'src="index.js"');
  writeFileSync(paths.options.outHtml, html);

  // Copy CSS file
  copyFileSync(
    resolve(__dirname, paths.options.srcCss),
    paths.options.outCss
  );

  // Update manifest.json to use built files
  const manifest = JSON.parse(readFileSync(resolve(__dirname, paths.manifest.src), 'utf-8'));

  // Update file references to point to built JS and CSS files
  manifest.content_scripts[0].js = ['content/index.js'];
  manifest.content_scripts[0].css = [paths.content.outCss];
  manifest.options_page = 'options/index.html';

  writeFileSync(
    paths.manifest.out,
    JSON.stringify(manifest, null, 2)
  );

  console.log('✓ Build completed successfully');
} catch (error) {
  console.error('✗ Build failed:', error);
  process.exit(1);
}
