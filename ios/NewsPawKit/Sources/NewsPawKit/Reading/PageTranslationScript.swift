import Foundation

/// The script that reads and replaces the text of a web page for in-place
/// translation (spec N06, N12; RD16 decisions 3, 4, 6 and 8). It runs only
/// through `PageScriptBridge`'s one call, in the app's own content world,
/// in the main frame, as the body of an async function whose arguments are
/// `command` (`collect`, `apply` or `end`) and `input`; nothing of a page
/// or of a model is ever spliced into it. Kept as a Swift string so that
/// its static check reads exactly the text that runs.
///
/// What it does:
/// - `collect`: on the first call in a document it makes its state, an own
///   property of the world's global named `stateName`, with a mutation
///   observer and a passive capture-phase `scroll` listener that only set a
///   dirty flag. It answers `{held: true}` while a field has focus,
///   `{unchanged: true}` when nothing changed since the last walk, and
///   otherwise the displayed runs in and near the viewport.
/// - `apply`: writes translations into recorded text nodes that still hold
///   exactly their original and are under no excluded element; marks runs
///   the app has settled; reports which runs still hold their original.
/// - `end`: puts back every recorded original whose node still holds what
///   the script wrote, then removes the observer, the listener and the
///   state.
///
/// It reaches the DOM only through functions and getters of the world's
/// own prototypes, never through a property a named element can shadow;
/// it never adds, removes, re-creates or moves a node and never sets an
/// attribute: it writes `data` of text nodes only.
enum PageTranslationScript {
    /// The name of the script's state on the world's global.
    static let stateName = "__newsPawPageTranslation"

    static let source = #"""
"use strict";
const NAME = "__newsPawPageTranslation";
const G = globalThis;
const own = Object.prototype.hasOwnProperty;
const describe = Object.getOwnPropertyDescriptor;
const getterOf = (proto, key) => {
  const found = describe(proto, key);
  return found && found.get ? found.get : null;
};
const DOC = Document.prototype;
const NODE = Node.prototype;
const ELEMENT = Element.prototype;
const HTML = HTMLElement.prototype;
const DATA = CharacterData.prototype;
const RANGE = Range.prototype;
const doc = document;
const readyStateOf = getterOf(DOC, "readyState");
const rootOf = getterOf(DOC, "documentElement");
const activeOf = getterOf(DOC, "activeElement");
const shadowActiveOf = getterOf(ShadowRoot.prototype, "activeElement") || getterOf(DOC, "activeElement");
const parentOf = getterOf(NODE, "parentElement");
const connectedOf = getterOf(NODE, "isConnected");
const nameOf = getterOf(ELEMENT, "localName");
const shadowOf = getterOf(ELEMENT, "shadowRoot");
const editableOf = getterOf(HTML, "isContentEditable");
const dataOf = getterOf(DATA, "data");
const setData = describe(DATA, "data").set;
const attributeOf = ELEMENT.getAttribute;
const hasAttribute = ELEMENT.hasAttribute;
const visibleOf = ELEMENT.checkVisibility;
const boxOf = ELEMENT.getBoundingClientRect;
const makeWalker = DOC.createTreeWalker;
const pointOf = DOC.elementFromPoint;
const makeRange = DOC.createRange;
const selectContents = RANGE.selectNodeContents;
const rangeRects = RANGE.getClientRects;
const styleOf = G.getComputedStyle;
const listen = EventTarget.prototype.addEventListener;
const unlisten = EventTarget.prototype.removeEventListener;
const windowValue = (key) => {
  const found = describe(G, key) || describe(Window.prototype, key);
  return found && found.get ? found.get.call(G) : G[key];
};

const LETTER = /\p{L}/u;
const SPACE = /\s+/g;
const EXCLUDED = new Set(["head", "title", "script", "style", "noscript", "template", "textarea", "input", "select",
  "option", "optgroup", "datalist", "pre", "code", "kbd", "samp", "svg", "math", "canvas", "iframe", "object", "embed",
  "video", "audio"]);
const FIELDS = new Set(["input", "textarea", "select", "iframe", "frame", "object", "embed"]);
const FOCUSABLE = new Set(["a", "area", "button", "summary", "details", "audio", "video", "body", "html"]);
const VISIT_BOUND = 50000;
const OUTSIDE_BOUND = 300;
const RUNS_BOUND = 500;
const UNITS_BOUND = 200000;
const RUN_UNITS_BOUND = 20000;
const RECORDS_BOUND = 20000;
const WHOLE_BOUND = 2000;
const DEPTH_BOUND = 32;

const normalised = (text) => text.replace(SPACE, " ").trim();

function makeState() {
  const state = {
    ids: new WeakMap(), records: new Map(), nextId: 1, recorded: 0, blocks: new WeakMap(), nextBlock: 1,
    dirty: true, view: null, observer: null, onScroll: null
  };
  state.observer = new MutationObserver(() => { state.dirty = true; });
  state.observer.observe(doc, { subtree: true, childList: true, characterData: true, attributes: true });
  state.onScroll = () => { state.dirty = true; };
  listen.call(G, "scroll", state.onScroll, { capture: true, passive: true });
  Object.defineProperty(G, NAME, { value: state, configurable: true, enumerable: false, writable: false });
  return state;
}

function isExcludedElement(element) {
  if (EXCLUDED.has(nameOf.call(element))) return true;
  const translate = attributeOf.call(element, "translate");
  if (translate !== null && translate.trim().toLowerCase() === "no") return true;
  const classes = attributeOf.call(element, "class");
  return classes !== null && /(^|\s)notranslate(\s|$)/.test(classes);
}

function underExcluded(node, cache) {
  const parent = parentOf.call(node);
  if (!parent) return true;
  if (parent instanceof HTMLElement && editableOf.call(parent)) return true;
  const chain = [];
  let element = parent;
  let result = false;
  while (element) {
    if (cache && cache.has(element)) { result = cache.get(element); break; }
    chain.push(element);
    if (isExcludedElement(element)) { result = true; break; }
    element = parentOf.call(element);
  }
  if (cache) for (const item of chain) cache.set(item, result);
  return result;
}

function rectsOf(node, range) {
  selectContents.call(range, node);
  const list = rangeRects.call(range);
  const rects = [];
  for (let index = 0; index < list.length; index++) {
    const rect = list[index];
    if (rect.width >= 2 && rect.height >= 2) rects.push(rect);
  }
  return rects;
}

function clipsToNothing(element, cache) {
  if (cache.has(element)) return cache.get(element);
  const style = styleOf.call(G, element);
  const overflowX = style.getPropertyValue("overflow-x");
  const overflowY = style.getPropertyValue("overflow-y");
  const clip = style.getPropertyValue("clip");
  const clipPath = style.getPropertyValue("clip-path");
  let tiny = false;
  if ((overflowX && overflowX !== "visible") || (overflowY && overflowY !== "visible") || (clip && clip !== "auto") ||
      (clipPath && clipPath !== "none")) {
    const box = boxOf.call(element);
    tiny = box.width < 2 || box.height < 2;
  }
  cache.set(element, tiny);
  return tiny;
}

function isDisplayed(node, rects, caches) {
  if (rects.length === 0) return false;
  const parent = parentOf.call(node);
  if (!parent || !visibleOf.call(parent, { opacityProperty: true, visibilityProperty: true })) return false;
  let element = parent;
  for (let depth = 0; element && depth < DEPTH_BOUND; depth++) {
    if (clipsToNothing(element, caches.clip)) return false;
    element = parentOf.call(element);
  }
  return true;
}

function displayOf(element, cache) {
  if (cache.has(element)) return cache.get(element);
  const value = styleOf.call(G, element).getPropertyValue("display");
  cache.set(element, value);
  return value;
}

function blockElementOf(node, caches) {
  let element = parentOf.call(node);
  while (element) {
    const display = displayOf(element, caches.display);
    if (display !== "inline" && display !== "contents") return element;
    const parent = parentOf.call(element);
    if (!parent) return element;
    element = parent;
  }
  return null;
}

function blockNumber(state, element) {
  let number = state.blocks.get(element);
  if (!number) {
    number = state.nextBlock++;
    state.blocks.set(element, number);
  }
  return number;
}

function wholeTextOf(block, caches, range) {
  if (caches.whole.has(block)) return caches.whole.get(block);
  const walker = makeWalker.call(doc, block, 4);
  const parts = [];
  let count = 0;
  let text = null;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (++count > WHOLE_BOUND) { caches.whole.set(block, null); return null; }
    if (blockElementOf(node, caches) !== block) continue;
    if (underExcluded(node, caches.excluded)) continue;
    if (!isDisplayed(node, rectsOf(node, range), caches)) continue;
    parts.push(dataOf.call(node));
  }
  text = normalised(parts.join(""));
  caches.whole.set(block, text);
  return text;
}

function focusHeld() {
  let element = activeOf.call(doc);
  for (let depth = 0; element && depth < DEPTH_BOUND; depth++) {
    const name = nameOf.call(element);
    if (FIELDS.has(name)) return true;
    if (element instanceof HTMLElement && editableOf.call(element)) return true;
    const root = shadowOf.call(element);
    if (root) {
      const inner = shadowActiveOf.call(root);
      if (!inner) return false;
      element = inner;
      continue;
    }
    if (FOCUSABLE.has(name)) return false;
    // Focus reported on an element that is not focusable itself: it is the
    // host of a closed shadow root that holds the focus, or a custom
    // element; counted as a field.
    if (name.indexOf("-") >= 0) return true;
    return !hasAttribute.call(element, "tabindex");
  }
  return false;
}

function sameView(left, right) {
  return right !== null && left.every((value, index) => value === right[index]);
}

function collect(state) {
  const loaded = readyStateOf.call(doc) === "complete";
  if (focusHeld()) return { held: true, loaded: loaded };
  const view = [windowValue("scrollX"), windowValue("scrollY"), windowValue("innerWidth"), windowValue("innerHeight")];
  if (!state.dirty && sameView(view, state.view)) return { unchanged: true, loaded: loaded };
  state.dirty = false;
  state.view = view;
  const width = view[2];
  const height = view[3];
  const bandTop = -height / 2;
  const bandBottom = height * 2;
  const root = rootOf.call(doc);
  if (!root) return { runs: [], loaded: loaded };
  const range = makeRange.call(doc);
  const caches = { excluded: new Map(), clip: new Map(), display: new Map(), whole: new Map() };
  let start = pointOf.call(doc, width / 2, height / 2);
  if (start) {
    const name = nameOf.call(start);
    if (name === "html" || name === "body") start = null;
  }
  const found = [];
  let full = false;

  function consider(node, direction, counter) {
    const data = dataOf.call(node);
    if (!LETTER.test(data)) return;
    let id = state.ids.get(node);
    let record = id ? state.records.get(id) : undefined;
    let taken = false;
    if (record) {
      if (record.state === "written" && data === record.written) taken = true;
      else if (record.state === "settled" && data === record.original) taken = true;
      else if (record.state === "seen" && data === record.original) taken = false;
      else { state.records.delete(id); state.ids.delete(node); record = undefined; id = undefined; }
    }
    const rects = rectsOf(node, range);
    if (rects.length === 0) return;
    let inBand = false;
    let inView = false;
    let beyond = true;
    for (const rect of rects) {
      const vertical = rect.bottom > bandTop && rect.top < bandBottom;
      if (vertical) beyond = false;
      else if (direction > 0 ? rect.top < bandBottom : rect.bottom > bandTop) beyond = false;
      const across = rect.right > 0 && rect.left < width;
      if (vertical && across) inBand = true;
      if (across && rect.bottom > 0 && rect.top < height) inView = true;
    }
    if (beyond) { counter.outside++; return; }
    counter.outside = 0;
    if (taken || !inBand || full) return;
    const text = normalised(data);
    if (text.length === 0 || text.length > RUN_UNITS_BOUND) return;
    if (underExcluded(node, caches.excluded)) return;
    if (!isDisplayed(node, rects, caches)) return;
    if (!record) {
      if (state.recorded >= RECORDS_BOUND) return;
      id = state.nextId++;
      record = { node: node, original: data, written: null, state: "seen" };
      state.records.set(id, record);
      state.ids.set(node, id);
      state.recorded++;
    }
    const block = blockElementOf(node, caches);
    if (!block) return;
    const whole = wholeTextOf(block, caches, range) === text;
    found.push({ id: id, block: blockNumber(state, block), text: text, whole: whole, inView: inView, direction: direction });
    if (found.length >= RUNS_BOUND * 2) full = true;
  }

  const forward = makeWalker.call(doc, root, 4);
  if (start) forward.currentNode = start;
  const forwardCounter = { outside: 0 };
  let visits = 0;
  for (let node = forward.nextNode(); node && visits < VISIT_BOUND; node = forward.nextNode()) {
    visits++;
    consider(node, 1, forwardCounter);
    if (forwardCounter.outside >= OUTSIDE_BOUND || full) break;
  }
  const earlier = [];
  if (start) {
    const backward = makeWalker.call(doc, root, 4);
    backward.currentNode = start;
    const backwardCounter = { outside: 0 };
    const mark = found.length;
    visits = 0;
    for (let node = backward.previousNode(); node && visits < VISIT_BOUND; node = backward.previousNode()) {
      visits++;
      consider(node, -1, backwardCounter);
      if (backwardCounter.outside >= OUTSIDE_BOUND || full) break;
    }
    for (const item of found.splice(mark)) earlier.push(item);
    earlier.reverse();
  }
  const ordered = earlier.concat(found);
  const sorted = ordered.filter((run) => run.inView).concat(ordered.filter((run) => !run.inView));
  const runs = [];
  let units = 0;
  for (const run of sorted) {
    if (runs.length >= RUNS_BOUND || units + run.text.length > UNITS_BOUND) { state.dirty = true; break; }
    units += run.text.length;
    runs.push({ id: run.id, block: run.block, text: run.text, whole: run.whole, inView: run.inView });
  }
  if (full) state.dirty = true;
  return { runs: runs, loaded: loaded };
}

function holdsOriginal(record) {
  return connectedOf.call(record.node) && dataOf.call(record.node) === record.original && !underExcluded(record.node, null);
}

function apply(state, input) {
  const written = [];
  const skipped = [];
  const holding = [];
  const writes = Array.isArray(input.writes) ? input.writes : [];
  for (const entry of writes) {
    const id = Array.isArray(entry) ? entry[0] : undefined;
    const text = Array.isArray(entry) ? entry[1] : undefined;
    const record = state ? state.records.get(id) : undefined;
    if (!record || typeof text !== "string" || record.state === "written" || !holdsOriginal(record)) {
      skipped.push(id);
      continue;
    }
    const lead = /^\s/.test(record.original) ? " " : "";
    const trail = /\s$/.test(record.original) ? " " : "";
    const value = lead + text + trail;
    setData.call(record.node, value);
    record.written = value;
    record.state = "written";
    written.push(id);
  }
  const settle = Array.isArray(input.settle) ? input.settle : [];
  for (const id of settle) {
    const record = state ? state.records.get(id) : undefined;
    if (record && record.state === "seen") record.state = "settled";
  }
  const check = Array.isArray(input.check) ? input.check : [];
  for (const id of check) {
    const record = state ? state.records.get(id) : undefined;
    if (record && record.state !== "written" && holdsOriginal(record)) holding.push(id);
  }
  if (state) state.dirty = true;
  return { written: written, skipped: skipped, holding: holding };
}

function end(state, input) {
  if (!state) return { had: false, restored: 0 };
  let restored = 0;
  if (input && input.restore === true) {
    for (const record of state.records.values()) {
      if (record.state === "written" && dataOf.call(record.node) === record.written) {
        setData.call(record.node, record.original);
        restored++;
      }
    }
  }
  state.observer.disconnect();
  unlisten.call(G, "scroll", state.onScroll, { capture: true, passive: true });
  delete G[NAME];
  return { had: true, restored: restored };
}

const existing = own.call(G, NAME) ? G[NAME] : null;
if (command === "collect") return collect(existing || makeState());
if (command === "apply") return apply(existing, input || {});
if (command === "end") return end(existing, input || {});
return { error: "command" };
"""#
}
