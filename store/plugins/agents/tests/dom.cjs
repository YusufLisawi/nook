// Small in-memory DOM used only to run the shipped plugin with a mocked bridge, without a browser or Nook.
module.exports = function createDOM(html) {
  const ids = new Map();
  const document = { activeElement: null, events: {} };
  class Element {
    constructor(tag = '') {
      this.tagName = tag.toUpperCase(); this.children = []; this.value = ''; this._text = '';
      this.hidden = false; this.disabled = false; this.className = ''; this.events = {};
      this.scrollHeight = 200; this.scrollTop = 200; this.clientHeight = 200;
    }
    set id(value) { this._id = value; ids.set(value, this); }
    get id() { return this._id; }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    append(...children) {
      for (const child of children) {
        if (child.tagName === '#FRAGMENT') { this.append(...child.children); continue; }
        child.parentElement = this; this.children.push(child);
      }
    }
    replaceChildren(...children) { this.children = []; this._text = ''; this.append(...children); }
    replaceWith(element) {
      const parent = this.parentElement;
      if (parent) { parent.children.splice(parent.children.indexOf(this), 1, element); element.parentElement = parent; }
    }
    remove() {
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(c => c !== this);
    }
    contains(element) { return this === element || this.children.some(c => c.contains?.(element)); }
    setAttribute(key, value) { this[key] = value; }
    addEventListener(type, callback) { (this.events[type] ||= []).push(callback); }
    querySelectorAll(selector) {
      const matches = element => selector.split(',').some(part => {
        part = part.trim();
        if (part.startsWith('.')) return element.className.split(' ').includes(part.slice(1));
        return element.tagName === part.split(':')[0].toUpperCase() && (!part.includes(':disabled') || !element.disabled);
      });
      const descend = element => element.children.flatMap(c => [c, ...descend(c)]);
      return descend(this).filter(matches);
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    focus() { document.activeElement = this; }
    scrollIntoView() {}
  }
  document.createElement = tag => new Element(tag);
  document.createTextNode = text => { const n = new Element('#text'); n.textContent = text; return n; };
  document.createDocumentFragment = () => new Element('#fragment');
  document.getElementById = id => ids.get(id) || null;
  document.addEventListener = (type, callback) => { (document.events[type] ||= []).push(callback); };
  for (const match of html.matchAll(/<(\w+)([^>]*\bid="([^"]+)"[^>]*)>/g)) {
    const element = document.createElement(match[1]); element.id = match[3];
    element.hidden = /\bhidden\b/.test(match[2]);
    element.value = /\bvalue="([^"]*)"/.exec(match[2])?.[1] || '';
    element.checked = /\bchecked\b/.test(match[2]);
  }
  // Only the dialog focus-trap needs the static tree; rendered rail/transcript/choices are built by main.js.
  for (const [parent, children] of [
    ['switcher', ['search', 'choices']],
    ['create', ['create-form']],
    ['create-form', ['create-name', 'create-instructions', 'create-directory', 'create-access', 'create-cancel', 'create-save']]
  ]) ids.get(parent).append(...children.map(id => ids.get(id)));
  return document;
};
