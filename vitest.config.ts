import { defineConfig } from 'vitest/config';
import { fileURLToPath } from 'url';
import path from 'path';

export default defineConfig({
  test: {
    // Enable global test APIs (describe, it, expect without imports)
    globals: true,

    // DOM environment emulation (happy-dom is fast)
    environment: 'happy-dom',

    // Test setup file
    setupFiles: ['./src/test-setup.ts'],

    // Coverage configuration
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html', 'lcov'],

      // 70%+ coverage target (critical paths only)
      thresholds: {
        lines: 70,
        functions: 70,
        branches: 70,
        statements: 70,
      },

      // Files excluded from coverage
      exclude: [
        'node_modules/',
        'dist/',
        '**/*.test.ts',
        '**/*.spec.ts',
        'src/test-setup.ts',
        'build.mjs',
        'vitest.config.ts',
      ],
    },

    // Test timeout (default 5s)
    testTimeout: 10000,

    // Parallel execution
    maxConcurrency: 5,
  },

  // Path alias resolution (matches tsconfig.json)
  resolve: {
    alias: {
      '@': path.resolve(path.dirname(fileURLToPath(import.meta.url)), './src'),
    },
  },
});
