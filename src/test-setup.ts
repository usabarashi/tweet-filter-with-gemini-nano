import { vi, beforeEach } from 'vitest';

/**
 * Chrome Extension API mock setup
 *
 * This file runs before all tests to mock Chrome APIs.
 * A complete mock is required since Chrome APIs do not exist in the happy-dom environment.
 */

// Chrome Storage API mock
const createStorageMock = () => ({
  get: vi.fn((_keys?: unknown, callback?: () => void) => {
    if (callback) {
      callback();
    }
    return Promise.resolve({});
  }),
  set: vi.fn((_items?: unknown, callback?: () => void) => {
    if (callback) {
      callback();
    }
    return Promise.resolve();
  }),
  remove: vi.fn((_keys?: unknown, callback?: () => void) => {
    if (callback) {
      callback();
    }
    return Promise.resolve();
  }),
  clear: vi.fn((callback?: () => void) => {
    if (callback) {
      callback();
    }
    return Promise.resolve();
  }),
});

// Chrome Runtime API mock
const runtimeMock = {
  sendMessage: vi.fn((_message?: unknown, callback?: (response: unknown) => void) => {
    if (callback) {
      callback({ success: true });
    }
    return Promise.resolve({ success: true });
  }),
  onMessage: {
    addListener: vi.fn(),
    removeListener: vi.fn(),
    hasListener: vi.fn(),
  },
  getContexts: vi.fn(() => Promise.resolve([])),
  id: 'test-extension-id',
  getURL: vi.fn((path: string) => `chrome-extension://test-extension-id/${path}`),
  lastError: undefined as chrome.runtime.LastError | undefined,
};

// Chrome Offscreen API mock
const offscreenMock = {
  createDocument: vi.fn(() => Promise.resolve()),
  closeDocument: vi.fn(() => Promise.resolve()),
  hasDocument: vi.fn(() => Promise.resolve(false)),
  Reason: {
    WORKERS: 'WORKERS',
  },
};

// Chrome Storage onChanged listener
const storageOnChangedMock = {
  addListener: vi.fn(),
  removeListener: vi.fn(),
  hasListener: vi.fn(),
};

// Chrome I18n API mock
const i18nMock = {
  getMessage: vi.fn((messageName: string) => {
    // Return default messages
    const messages: Record<string, string> = {
      tweetHidden: 'Tweet hidden by filter',
      showButton: 'Show',
    };
    return messages[messageName] || messageName;
  }),
  getUILanguage: vi.fn(() => 'en'),
};

// Create global chrome object
(globalThis as any).chrome = {
  runtime: runtimeMock,
  storage: {
    sync: createStorageMock(),
    session: createStorageMock(),
    local: createStorageMock(),
    onChanged: storageOnChangedMock,
  },
  offscreen: offscreenMock,
  i18n: i18nMock,
};

// Reset mocks before each test
beforeEach(() => {
  vi.clearAllMocks();
});

// Test utility functions
export const mockChromeStorage = (storageType: 'sync' | 'session' | 'local', data: any) => {
  (chrome.storage[storageType].get as any).mockImplementation(
    (_keys: string | string[] | null, callback?: (result: any) => void) => {
      if (callback) {
        callback(data);
      }
      return Promise.resolve(data);
    }
  );
};

export const mockChromeSendMessage = (response: any) => {
  (chrome.runtime.sendMessage as any).mockImplementation(
    (_message: any, callback?: (response: any) => void) => {
      if (callback) {
        callback(response);
      }
      return Promise.resolve(response);
    }
  );
};

// Chrome Runtime lastError mock
export const mockChromeRuntimeError = (errorMessage: string) => {
  (runtimeMock as any).lastError = { message: errorMessage } as chrome.runtime.LastError;
};

export const clearChromeRuntimeError = () => {
  (runtimeMock as any).lastError = undefined;
};
