// FFI for chrome.runtime API

export const isContextValid = () => {
  return !!(chrome.runtime && chrome.runtime.id);
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
