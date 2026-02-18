// FFI for LanguageModel (Gemini Nano) API

export const checkAvailabilityImpl = (opts) => () => {
  return LanguageModel.availability(opts);
};

export const createSessionImpl = (opts) => () => {
  return LanguageModel.create(opts);
};

export const getParamsImpl = () => {
  return LanguageModel.params();
};

export const promptTextImpl = (session) => (text) => (signal) => () => {
  const opts = signal ? { signal } : {};
  return session.prompt(text, opts);
};

export const promptMultimodalImpl = (session) => (messages) => (signal) => () => {
  const opts = signal ? { signal } : {};
  return session.prompt(messages, opts);
};

export const cloneSessionImpl = (session) => (signal) => () => {
  const opts = signal ? { signal } : {};
  return session.clone(opts);
};

export const destroySessionImpl = (session) => () => {
  return Promise.resolve(session.destroy());
};

export const getInputUsage = (session) => () => {
  return session.inputUsage;
};

export const getInputQuota = (session) => () => {
  return session.inputQuota;
};

// Create session with download progress monitor callback
export const createSessionWithMonitorImpl = (opts) => (onProgress) => () => {
  const options = Object.assign({}, opts, {
    monitor: (m) => {
      m.addEventListener("downloadprogress", (e) => {
        onProgress(e.loaded * 100)();
      });
    },
  });
  return LanguageModel.create(options);
};

// Check if LanguageModel API is available
export const isLanguageModelAvailable = () => {
  return typeof LanguageModel !== "undefined";
};
