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
///   observer and passive capture-phase `scroll`, `change`, `input`,
///   `click`, `toggle` and `transitionend` listeners that only set a dirty
///   flag (the last five for text that CSS alone reveals). It answers `{held: true}` while a field has focus,
///   `{unchanged: true}` when nothing changed since the last walk, and
///   otherwise the displayed runs in and near the viewport. Its input names
///   the app's `period` (the document generation) and the reading `locale`:
///   a new period walks the page again and forgets what the app settled; a
///   new locale puts back what was written for the old one, and those runs
///   are given again.
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
const clientLeftOf = getterOf(ELEMENT, "clientLeft");
const clientTopOf = getterOf(ELEMENT, "clientTop");
const clientWidthOf = getterOf(ELEMENT, "clientWidth");
const clientHeightOf = getterOf(ELEMENT, "clientHeight");
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
// The standard elements that can host a shadow root (body aside: focus
// rests there by default).
const HOSTS = new Set(["article", "aside", "blockquote", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "main",
  "nav", "p", "section", "span"]);
const REVEALING = ["change", "input", "click", "toggle", "transitionend"];
const VISIT_BOUND = 50000;
const OUTSIDE_BOUND = 300;
const RUNS_BOUND = 500;
const UNITS_BOUND = 200000;
const RUN_UNITS_BOUND = 20000;
const RECORDS_BOUND = 20000;
const WHOLE_BOUND = 2000;
const DEPTH_BOUND = 32;

const normalised = (text) => text.replace(SPACE, " ").trim();

function makeToken() {
  const bits = new Uint32Array(2);
  crypto.getRandomValues(bits);
  return bits[0].toString(36) + "-" + bits[1].toString(36);
}

function makeState() {
  const state = {
    token: makeToken(), ids: new WeakMap(), records: new Map(), nextId: 1, recorded: 0, written: 0, blocks: new WeakMap(),
    nextBlock: 1, dirty: true, view: null, observer: null, onScroll: null, period: null, locale: null
  };
  state.observer = new MutationObserver(() => { state.dirty = true; });
  state.observer.observe(doc, { subtree: true, childList: true, characterData: true, attributes: true });
  state.onScroll = () => { state.dirty = true; };
  listen.call(G, "scroll", state.onScroll, { capture: true, passive: true });
  // What reveals text through CSS alone (a :checked tab, an opened
  // details, a transition) changes no node: these events only set the flag.
  for (const type of REVEALING) listen.call(G, type, state.onScroll, { capture: true, passive: true });
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

// A length of a clip-path's or clip's computed value in points, against
// `size` for a percentage; null for anything else (calc(), keywords).
function lengthOf(text, size) {
  const match = /^(-?[0-9.]+)(px|%)?$/.exec(text);
  if (!match) return null;
  const value = parseFloat(match[1]);
  return match[2] === "%" ? value * size / 100 : value;
}

// Whether a clip-path or a legacy clip leaves the element no area, read from
// the computed value alone: an inset() whose opposite insets reach across
// the box, a circle() or an ellipse() of radius 0, a zero rect(). Any other
// shape (a polygon, a path, a reference) counts as leaving area.
function clipsAway(style, box) {
  const clipPath = style.getPropertyValue("clip-path");
  if (clipPath && clipPath !== "none") {
    let match = /^inset\(([^)]*)\)/.exec(clipPath);
    if (match) {
      const parts = match[1].split(" round ")[0].trim().split(/\s+/);
      const sides = [parts[0], parts[1] || parts[0], parts[2] || parts[0], parts[3] || parts[1] || parts[0]];
      const top = lengthOf(sides[0], box.height);
      const right = lengthOf(sides[1], box.width);
      const bottom = lengthOf(sides[2], box.height);
      const left = lengthOf(sides[3], box.width);
      if (top !== null && bottom !== null && top + bottom >= box.height) return true;
      if (left !== null && right !== null && left + right >= box.width) return true;
    }
    match = /^circle\(\s*([^\s)]+)/.exec(clipPath);
    if (match && lengthOf(match[1], 1) === 0) return true;
    match = /^ellipse\(\s*([^\s)]+)\s+([^\s)]+)/.exec(clipPath);
    if (match && (lengthOf(match[1], 1) === 0 || lengthOf(match[2], 1) === 0)) return true;
  }
  const position = style.getPropertyValue("position");
  const clip = style.getPropertyValue("clip");
  if (clip && clip !== "auto" && (position === "absolute" || position === "fixed")) {
    const match = /^rect\(([^)]*)\)/.exec(clip);
    if (match) {
      const sides = match[1].split(/[\s,]+/).filter((part) => part.length > 0);
      if (sides.length === 4) {
        const top = sides[0] === "auto" ? 0 : lengthOf(sides[0], box.height);
        const right = sides[1] === "auto" ? box.width : lengthOf(sides[1], box.width);
        const bottom = sides[2] === "auto" ? box.height : lengthOf(sides[2], box.height);
        const left = sides[3] === "auto" ? 0 : lengthOf(sides[3], box.width);
        if (top !== null && right !== null && bottom !== null && left !== null && (right - left < 2 || bottom - top < 2)) return true;
      }
    }
  }
  return false;
}

// Whether an element is the containing block of its fixed-position
// descendants (a transform, a filter, layout or paint containment, a
// container, or a will-change naming one of them): its overflow, and its
// ancestors', clips them as any other descendant. When in doubt it counts
// as one, so that text is left out rather than sent.
const NONE_UNLESS_CONTAINING = ["transform", "translate", "rotate", "scale", "perspective", "filter", "backdrop-filter",
  "-webkit-backdrop-filter"];
function containsFixed(style) {
  for (const property of NONE_UNLESS_CONTAINING) {
    const value = style.getPropertyValue(property);
    if (value && value !== "none") return true;
  }
  if (/(^|\s)(layout|paint|strict|content)(\s|$)/.test(style.getPropertyValue("contain") || "")) return true;
  const container = style.getPropertyValue("container-type");
  if (container && container !== "normal") return true;
  const willChange = style.getPropertyValue("will-change") || "";
  return /(^|[\s,])(transform|translate|rotate|scale|perspective|filter|backdrop-filter|-webkit-backdrop-filter|contain)([\s,]|$)/.test(willChange);
}

// What an element does to the text inside it, read once per collection:
// whether it hides it whatever its place (a box under 2 points with a clip,
// a clip-path or clip that leaves no area), which axes its overflow (or
// `contain: paint`) clips and its clipping box, whether it is fixed in place
// (its descendants then escape the overflow of the ancestors above it, up to
// the nearest containing block of fixed descendants), and whether it is
// such a containing block.
function clipInfoOf(element, cache) {
  if (cache.has(element)) return cache.get(element);
  const style = styleOf.call(G, element);
  const name = nameOf.call(element);
  const overflowX = style.getPropertyValue("overflow-x");
  const overflowY = style.getPropertyValue("overflow-y");
  const contain = style.getPropertyValue("contain");
  const paint = /(^|\s)(paint|strict|content)(\s|$)/.test(contain || "");
  const clip = style.getPropertyValue("clip");
  const clipPath = style.getPropertyValue("clip-path");
  // The root's and the body's overflow belong to the viewport, which the
  // band deals with.
  const clipsX = name !== "html" && name !== "body" && (paint || (overflowX && overflowX !== "visible"));
  const clipsY = name !== "html" && name !== "body" && (paint || (overflowY && overflowY !== "visible"));
  const clipping = clipsX || clipsY || (clip && clip !== "auto") || (clipPath && clipPath !== "none");
  const info = {
    hidden: false, clipsX: clipsX, clipsY: clipsY, box: null, fixed: style.getPropertyValue("position") === "fixed",
    containing: containsFixed(style)
  };
  if (clipping) {
    const box = boxOf.call(element);
    info.hidden = box.width < 2 || box.height < 2 || clipsAway(style, box);
    if (clipsX || clipsY) {
      const left = box.left + clientLeftOf.call(element);
      const top = box.top + clientTopOf.call(element);
      info.box = { left: left, top: top, right: left + clientWidthOf.call(element), bottom: top + clientHeightOf.call(element) };
    }
  }
  cache.set(element, info);
  return info;
}

// Displayed: the parent is visible, no ancestor hides it, and a part of at
// least 2 by 2 points of one of its rectangles is left once the rectangles
// are cut, ancestor by ancestor, to the clipping box of every ancestor whose
// overflow clips them (on the axes it clips): what one ancestor cuts away
// is not given back by the next. A fixed-position ancestor's
// descendants escape the overflow of the ancestors above it only up to the
// nearest one that is the containing block of fixed descendants: from that
// one upwards the clipping applies again. With a `band` (the collection's
// translation band) the rectangles are first cut to it, so that only a part
// that is both in the band and left by the clips counts.
function isDisplayed(node, rects, caches, band) {
  if (rects.length === 0) return false;
  const parent = parentOf.call(node);
  if (!parent || !visibleOf.call(parent, { opacityProperty: true, visibilityProperty: true })) return false;
  let shown = rects.map((rect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom }));
  if (band) {
    shown = shown.map((rect) => ({
      left: Math.max(rect.left, band.left), right: Math.min(rect.right, band.right),
      top: Math.max(rect.top, band.top), bottom: Math.min(rect.bottom, band.bottom)
    })).filter((rect) => rect.right - rect.left >= 2 && rect.bottom - rect.top >= 2);
    if (shown.length === 0) return false;
  }
  let escaped = false;
  let element = parent;
  while (element) {
    const info = clipInfoOf(element, caches.clip);
    if (info.hidden) return false;
    if (info.containing) escaped = false;
    if (!escaped && info.box) {
      const box = info.box;
      shown = shown.map((rect) => ({
        left: info.clipsX ? Math.max(rect.left, box.left) : rect.left,
        right: info.clipsX ? Math.min(rect.right, box.right) : rect.right,
        top: info.clipsY ? Math.max(rect.top, box.top) : rect.top,
        bottom: info.clipsY ? Math.min(rect.bottom, box.bottom) : rect.bottom
      })).filter((rect) => rect.right - rect.left >= 2 && rect.bottom - rect.top >= 2);
      if (shown.length === 0) return false;
    }
    if (info.fixed) escaped = true;
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
    // An element that can host a shadow root and shows none: it may host a
    // closed one whose field holds the focus, which the script cannot see
    // into. Counted as a field, whatever its tabindex.
    if (name.indexOf("-") >= 0 || HOSTS.has(name)) return true;
    // Focus reported on another element that is not focusable itself.
    return !hasAttribute.call(element, "tabindex");
  }
  return false;
}

function sameView(left, right) {
  return right !== null && left.every((value, index) => value === right[index]);
}

// What the state kept from before this call that the app no longer knows
// of. Writes made for another reading language are put back where the node
// still holds them (the page's own change wins: that record is forgotten),
// and their runs are given again. A new period (a document generation of
// the app: a page shown again from the back-forward cache, translation
// turned on again) forgets what the app settled, and walks the page even if
// nothing moved: the app has dropped what it had collected.
function follow(state, input) {
  const period = typeof input.period === "string" ? input.period : "";
  const locale = typeof input.locale === "string" ? input.locale : "";
  if (state.locale !== null && state.locale !== locale) {
    for (const [id, record] of state.records) {
      if (record.state !== "written") continue;
      if (dataOf.call(record.node) === record.written) {
        setData.call(record.node, record.original);
        record.state = "seen";
        record.written = null;
      } else {
        state.records.delete(id);
        state.ids.delete(record.node);
      }
      state.written -= 1;
    }
    state.dirty = true;
  }
  state.locale = locale;
  if (state.period !== period) {
    for (const record of state.records.values()) {
      if (record.state === "settled") record.state = "seen";
    }
    state.period = period;
    state.dirty = true;
  }
}

function collect(state, input) {
  const loaded = readyStateOf.call(doc) === "complete";
  const token = state.token;
  if (focusHeld()) return { held: true, loaded: loaded, written: state.written > 0, state: token };
  follow(state, input);
  const written = state.written > 0;
  const view = [windowValue("scrollX"), windowValue("scrollY"), windowValue("innerWidth"), windowValue("innerHeight")];
  if (!state.dirty && sameView(view, state.view)) return { unchanged: true, loaded: loaded, written: written, state: token };
  state.dirty = false;
  state.view = view;
  const width = view[2];
  const height = view[3];
  const bandTop = -height / 2;
  const bandBottom = height * 2;
  // The translation band: the viewport's width across, from half a viewport
  // above it to two viewports below its top.
  const band = { left: 0, top: bandTop, right: width, bottom: bandBottom };
  const root = rootOf.call(doc);
  if (!root) return { runs: [], loaded: loaded, written: written, state: token };
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
      else {
        // The page changed the node: a translation it held no longer counts.
        if (record.state === "written") state.written -= 1;
        state.records.delete(id); state.ids.delete(node); record = undefined; id = undefined;
      }
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
    if (!isDisplayed(node, rects, caches, band)) return;
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
  // Blocks with a run in view first, then the rest of the band; within a
  // block its runs keep document order, so a sentence is never sent middle
  // first.
  const viewBlocks = new Set(ordered.filter((run) => run.inView).map((run) => run.block));
  const sorted = ordered.filter((run) => viewBlocks.has(run.block)).concat(ordered.filter((run) => !viewBlocks.has(run.block)));
  const runs = [];
  let units = 0;
  for (const run of sorted) {
    if (runs.length >= RUNS_BOUND || units + run.text.length > UNITS_BOUND) { state.dirty = true; break; }
    units += run.text.length;
    runs.push({ id: run.id, block: run.block, text: run.text, whole: run.whole, inView: run.inView });
  }
  if (full) state.dirty = true;
  return { runs: runs, loaded: loaded, written: written, state: token };
}

function holdsOriginal(record) {
  return connectedOf.call(record.node) && dataOf.call(record.node) === record.original && !underExcluded(record.node, null);
}

function apply(state, input) {
  const written = [];
  const skipped = [];
  const holding = [];
  const writes = Array.isArray(input.writes) ? input.writes : [];
  // Run numbers belong to one state: a request for another writes,
  // settles and reports nothing.
  if (!state || input.state !== state.token) {
    for (const entry of writes) skipped.push(Array.isArray(entry) ? entry[0] : undefined);
    return { written: written, skipped: skipped, holding: holding, foreign: true };
  }
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
    state.written += 1;
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
  for (const type of REVEALING) unlisten.call(G, type, state.onScroll, { capture: true, passive: true });
  delete G[NAME];
  return { had: true, restored: restored };
}

const existing = own.call(G, NAME) ? G[NAME] : null;
if (command === "collect") return collect(existing || makeState(), input || {});
if (command === "apply") return apply(existing, input || {});
if (command === "end") return end(existing, input || {});
return { error: "command" };
"""#
}
