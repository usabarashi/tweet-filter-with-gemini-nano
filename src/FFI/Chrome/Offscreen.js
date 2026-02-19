// FFI for chrome.offscreen API

export const createDocumentImpl = (opts) => () => {
  return chrome.offscreen.createDocument({
    url: opts.url,
    reasons: opts.reasons,
    justification: opts.justification,
  });
};

export const closeDocumentImpl = () => {
  return chrome.offscreen.closeDocument();
};
