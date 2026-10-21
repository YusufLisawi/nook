// A small, deliberately safe Markdown renderer: content is always text, never model-provided HTML.
(() => {
  function inline(parent, text) {
    const tokens = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]+\]\([^\s)]+\))/g;
    let offset = 0;
    for (const match of text.matchAll(tokens)) {
      parent.append(document.createTextNode(text.slice(offset, match.index)));
      const value = match[0];
      let node;
      if (value.startsWith('`')) { node = document.createElement('code'); node.textContent = value.slice(1, -1); }
      else if (value.startsWith('**')) { node = document.createElement('strong'); node.textContent = value.slice(2, -2); }
      else if (value.startsWith('*')) { node = document.createElement('em'); node.textContent = value.slice(1, -1); }
      else {
        const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(value);
        if (link && /^https?:\/\//i.test(link[2])) {
          node = document.createElement('a'); node.href = link[2]; node.textContent = link[1];
          node.addEventListener('click', async event => {
            event.preventDefault();
            try { await nook.open(link[2]); } catch (error) { globalThis.agentShowError?.(error); }
          });
        } else { node = document.createTextNode(value); }
      }
      parent.append(node);
      offset = match.index + value.length;
    }
    parent.append(document.createTextNode(text.slice(offset)));
  }
  function markdown(text) {
    const fragment = document.createDocumentFragment();
    const lines = String(text || '').split('\n');
    let list = null;
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      if (/^\s*```/.test(line)) {
        list = null;
        const code = [];
        while (++index < lines.length && !/^\s*```/.test(lines[index])) code.push(lines[index]);
        const block = document.createElement('div'); block.className = 'code-block';
        const pre = document.createElement('pre'), content = document.createElement('code');
        content.textContent = code.join('\n'); pre.append(content);
        const copy = document.createElement('button'); copy.className = 'nk-btn nk-ghost'; copy.textContent = 'Copy';
        copy.type = 'button'; copy.setAttribute('aria-label', 'Copy code block');
        copy.onclick = async () => {
          try { await nook.clipboard.write(content.textContent); copy.textContent = 'Copied'; }
          catch (error) { globalThis.agentShowError?.(error); }
        };
        block.append(pre, copy); fragment.append(block); continue;
      }
      const bullet = /^\s*(?:([-*])|\d+\.)\s+(.+)$/.exec(line);
      if (bullet) {
        const tag = bullet[1] ? 'ul' : 'ol';
        if (!list || list.tagName.toLowerCase() !== tag) { list = document.createElement(tag); fragment.append(list); }
        const item = document.createElement('li'); inline(item, bullet[2]); list.append(item); continue;
      }
      list = null;
      if (!line.trim()) continue;
      const heading = /^#{1,6}\s+(.+)$/.exec(line);
      const paragraph = document.createElement(heading ? 'h3' : 'p');
      inline(paragraph, heading ? heading[1] : line);
      fragment.append(paragraph);
    }
    return fragment;
  }
  globalThis.agentMarkdown = markdown;
})();
