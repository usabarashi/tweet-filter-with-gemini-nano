// FFI for Web API helpers not covered by purescript-web-dom

export const getDataset = (el) => (key) => () => {
  return el.dataset[key] || null;
};

export const setDataset = (el) => (key) => (value) => () => {
  el.dataset[key] = value;
};

export const removeDataset = (el) => (key) => () => {
  delete el.dataset[key];
};

export const matches = (el) => (selector) => () => {
  return el.matches(selector);
};

export const isConnected = (el) => () => {
  return el.isConnected;
};

export const randomUUID = () => {
  return crypto.randomUUID();
};

export const dateNow = () => {
  return Date.now();
};

export const setTimeoutImpl = (callback) => (ms) => () => {
  return setTimeout(() => callback(), ms);
};

export const clearTimeoutImpl = (id) => () => {
  clearTimeout(id);
};

export const setIntervalImpl = (callback) => (ms) => () => {
  return setInterval(() => callback(), ms);
};

export const clearIntervalImpl = (id) => () => {
  clearInterval(id);
};

export const fetchBlobImpl = (url) => () => {
  return fetch(url).then((res) => res.blob());
};

export const getLocationHref = () => {
  return window.location.href;
};

export const addPopstateListener = (callback) => () => {
  const handler = () => callback();
  window.addEventListener("popstate", handler);
  return () => window.removeEventListener("popstate", handler);
};

export const querySelectorImpl = (el) => (selector) => () => {
  return el.querySelector(selector);
};

export const querySelectorAllImpl = (el) => (selector) => () => {
  return Array.from(el.querySelectorAll(selector));
};

export const getTextContent = (el) => () => {
  return el.textContent || "";
};

export const getInnerText = (el) => () => {
  return el.innerText || "";
};

export const createElementImpl = (tag) => () => {
  return document.createElement(tag);
};

export const setInnerHTML = (el) => (html) => () => {
  el.innerHTML = html;
};

export const setTextContent = (el) => (text) => () => {
  el.textContent = text;
};

export const addClickListener = (el) => (callback) => () => {
  const handler = (e) => callback(e)();
  el.addEventListener("click", handler);
  return () => el.removeEventListener("click", handler);
};

export const prependChild = (parent) => (child) => () => {
  parent.prepend(child);
};

export const setClassName = (el) => (name) => () => {
  el.className = name;
};

export const removeElement = (el) => () => {
  if (el.parentNode) {
    el.parentNode.removeChild(el);
  }
};

export const stopPropagation = (ev) => () => {
  ev.stopPropagation();
};

export const preventDefault = (ev) => () => {
  ev.preventDefault();
};

export const getAttributeImpl = (el) => (name) => () => {
  return el.getAttribute(name);
};

export const setAttributeImpl = (el) => (name) => (value) => () => {
  el.setAttribute(name, value);
};

export const removeAttributeImpl = (el) => (name) => () => {
  el.removeAttribute(name);
};

export const hasAttributeImpl = (el) => (name) => () => {
  return el.hasAttribute(name);
};

export const getSrcImpl = (el) => () => {
  return el.src || "";
};

export const getChildrenImpl = (el) => () => {
  return Array.from(el.children);
};

export const getClosestImpl = (el) => (selector) => () => {
  return el.closest(selector);
};

export const addEventListenerImpl = (el) => (event) => (callback) => () => {
  const handler = (e) => callback(e)();
  el.addEventListener(event, handler);
  return () => el.removeEventListener(event, handler);
};

export const skipWaiting = () => {
  self.skipWaiting();
};

export const addServiceWorkerEventListener = (event) => (callback) => () => {
  self.addEventListener(event, () => callback());
};

// Document-level queries

export const getDocumentBody = () => {
  return document.body;
};

export const documentQuerySelectorImpl = (selector) => () => {
  return document.querySelector(selector);
};

// DOM traversal

export const containsImpl = (parent) => (child) => () => {
  return parent.contains(child);
};

export const getParentElementImpl = (el) => () => {
  return el.parentElement;
};

// Safely coerce Node to Element (returns null if not an HTMLElement)

export const asElementImpl = (node) => () => {
  return node instanceof HTMLElement ? node : null;
};

// MutationObserver

export const newMutationObserverImpl = (callback) => () => {
  return new MutationObserver((mutations) => {
    const added = [];
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        added.push(node);
      }
    }
    callback(added)();
  });
};

export const observeImpl = (observer) => (target) => (opts) => () => {
  observer.observe(target, { childList: opts.childList, subtree: opts.subtree });
};

export const disconnectImpl = (observer) => () => {
  observer.disconnect();
};

// String helpers

export const normalizeImageUrlImpl = (url) => {
  return url
    .replace(/&name=\w+/, "&name=large")
    .replace(/\?format=(\w+)&name=\w+/, "?format=$1&name=large");
};

export const matchStatusIdImpl = (href) => {
  const m = href.match(/\/status\/(\d+)/);
  return m ? m[1] : null;
};

export const generateFallbackId = () => {
  return "tweet-" + Date.now() + "-" + Math.random().toString(36).substr(2, 9);
};

export const stringIncludesImpl = (str) => (sub) => {
  return str.includes(sub);
};

// Form element properties

export const getCheckedImpl = (el) => () => {
  return el.checked;
};

export const setCheckedImpl = (el) => (val) => () => {
  el.checked = val;
};

export const getValueImpl = (el) => () => {
  return el.value;
};

export const setValueImpl = (el) => (val) => () => {
  el.value = val;
};

export const setDisabledImpl = (el) => (val) => () => {
  el.disabled = val;
};

// Clipboard

export const clipboardWriteTextImpl = (text) => () => {
  return navigator.clipboard.writeText(text);
};

// Document-level querySelectorAll

export const documentQuerySelectorAllImpl = (selector) => () => {
  return Array.from(document.querySelectorAll(selector));
};

// CSS class manipulation

export const addClassImpl = (el) => (cls) => () => {
  el.classList.add(cls);
};

export const removeClassImpl = (el) => (cls) => () => {
  el.classList.remove(cls);
};

// beforeunload listener

export const addBeforeUnloadListener = (callback) => () => {
  const handler = () => callback();
  window.addEventListener("beforeunload", handler);
  return () => window.removeEventListener("beforeunload", handler);
};
