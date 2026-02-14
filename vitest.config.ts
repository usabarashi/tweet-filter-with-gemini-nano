import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  test: {
    // グローバルテストAPIを有効化（describe, it, expect等をインポート不要に）
    globals: true,

    // DOM環境のエミュレーション（happy-domは高速）
    environment: 'happy-dom',

    // テストセットアップファイル
    setupFiles: ['./src/test-setup.ts'],

    // カバレッジ設定
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html', 'lcov'],

      // 70%以上のカバレッジ目標（重要パスのみ）
      thresholds: {
        lines: 70,
        functions: 70,
        branches: 70,
        statements: 70,
      },

      // カバレッジから除外するファイル
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

    // テストタイムアウト（デフォルト5秒）
    testTimeout: 10000,

    // 並列実行の設定
    maxConcurrency: 5,
  },

  // パスエイリアスの解決（tsconfig.jsonと同じ）
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});
