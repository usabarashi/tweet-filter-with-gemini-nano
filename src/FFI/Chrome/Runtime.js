// FFI for chrome.runtime API

export const isContextValid = () => {
  try {
    return !!(typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
  } catch (_) {
    return false;
  }
};

export const sendMessageImpl = (msg) => () => {
  return chrome.runtime.sendMessage(msg);
};

export const addMessageListener = (handler) => () => {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    return handler(message)(sender)((resp) => () => sendResponse(resp))();
  });
};

export const getContextsImpl = (filter) => () => {
  return chrome.runtime.getContexts(filter);
};
