// State and bridge operations are DOM-independent so they can be exercised with a mocked window.nook.
(() => {
  class AgentsClient {
    constructor(api, changed = () => {}) {
      this.api = api;
      this.changed = changed;
      this.agents = [];
      this.chats = new Map();
      this.agentId = null;
      this.sessionId = null;
      this.sending = false;
      this.loading = true;
      this.error = '';
      this.selection = 0;
      this.visible = false;
      this.ownsPin = false;
      this.drafts = new Map();
    }
    get agent() { return this.agents.find(a => a.id === this.agentId); }
    get session() { return this.chats.get(this.sessionId); }
    get running() { return ['running', 'stopping'].includes(this.session?.status); }
    get draftKey() { return this.sessionId || this.agentId || 'empty'; }
    recent(agentId) { return [...this.chats.values()].filter(c => c.agentId === agentId).sort((a, b) => b.updatedAt - a.updatedAt); }
    apply(session, item) {
      if (!session?.id) return;
      const previous = this.chats.get(session.id);
      if (previous && previous.revision > session.revision) return;
      const items = session.items || previous?.items || [];
      const next = { ...previous, ...session, items: items.slice() };
      if (item) {
        const index = next.items.findIndex(i => i.id === item.id);
        if (index < 0) next.items.push(item); else next.items[index] = item;
      }
      this.chats.set(session.id, next);
      this.changed();
    }
    async load() {
      try {
        this.error = '';
        this.agents = await this.api.agents.list();
        const lists = await Promise.all(this.agents.map(a => this.api.agents.sessions(a.id)));
        lists.flat().forEach(s => this.apply(s));
        if (!this.agent) this.agentId = this.agents[0]?.id || null;
        this.loading = false;
        this.changed();
      } catch (error) { this.loading = false; this.fail(error); }
    }
    async select(agentId, sessionId = null) {
      const token = ++this.selection;
      this.agentId = agentId;
      this.sessionId = sessionId;
      this.error = '';
      this.changed();
      try {
        await this.releasePin();
        if (sessionId) {
          const session = await this.api.agents.open(sessionId);
          this.apply(session);
          if (token !== this.selection) return;
        }
      } catch (error) { if (token === this.selection) this.fail(error); }
    }
    async send(text) {
      if (this.sending || this.running || !this.agent || !text.trim()) return false;
      const agentId = this.agentId, selection = this.selection, draftKey = this.draftKey;
      const sessionId = this.sessionId;
      this.sending = true;
      this.error = '';
      this.changed();
      try {
        this.ownsPin = true;
        await this.api.notch.pin(true);
        const session = await this.api.agents.send(agentId, sessionId, text);
        this.apply(session);
        this.drafts.delete(draftKey);
        if (selection === this.selection) this.sessionId = session.id;
        return true;
      } catch (error) {
        this.fail(error);
        await this.releasePin();
        return false;
      } finally { this.sending = false; this.changed(); }
    }
    async cancel() {
      if (!this.sessionId || !this.running) return;
      try { await this.api.agents.cancel(this.sessionId); } catch (error) { this.fail(error); }
    }
    async leave() {
      this.visible = false;
      await this.releasePin();
    }
    async releasePin() {
      // Hidden web views receive every tab event. Only release a pin this chat requested.
      if (!this.ownsPin) return;
      this.ownsPin = false;
      try { await this.api.notch.pin(false); } catch (error) { this.fail(error); }
    }
    async activity() {
      const live = [...this.chats.values()].find(c => ['running', 'stopping'].includes(c.status));
      try {
        if (live) {
          const name = this.agents.find(a => a.id === live.agentId)?.name || 'Agent';
          await this.api.activity.set({ text: name.slice(0, 11) + '…', symbol: 'sparkles' });
        } else { await this.api.activity.clear(); }
      } catch (error) { this.fail(error); }
    }
    fail(error) { this.error = error?.message || String(error); this.changed(); }
  }
  globalThis.AgentsClient = AgentsClient;
})();
