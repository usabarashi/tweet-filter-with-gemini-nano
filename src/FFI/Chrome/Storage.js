// FFI for chrome.storage API

export const syncGetImpl = (keys) => () => {
  return chrome.storage.sync.get(keys);
};

export const syncSetImpl = (data) => () => {
  return chrome.storage.sync.set(data);
};

export const sessionGetImpl = (keys) => () => {
  return chrome.storage.session.get(keys);
};

export const sessionSetImpl = (data) => () => {
  return chrome.storage.session.set(data);
};

export const sessionRemoveImpl = (keys) => () => {
  return chrome.storage.session.remove(keys);
};

export const onChanged = (handler) => () => {
  const listener = (changes, areaName) => {
    handler(changes)(areaName)();
  };
  chrome.storage.onChanged.addListener(listener);
  return () => chrome.storage.onChanged.removeListener(listener);
};
