(() => {
'use strict'; const $ = id => document.getElementById(id);
const error = e => { $('error').hidden = !e; $('error').textContent = e ? String(e.message || e) : ''; };
async function set(key,value) { try { await nook.native.call('preferences.set',{key,value}); $('status').textContent = 'Saved'; } catch(e) { error(e); } }
async function load() { try {
 error(null); const p = await nook.native.call('preferences.get',{}); const devices = await nook.host.call('microphone.devices',{}); $('fields').replaceChildren();
 for (const [key,title,type] of [['dictationEngine','Engine',['chatgpt','groq']],['dictationMicUID','Microphone',devices],['dictationCleanup','Clean up transcription','check'],['dictationSounds','Sounds','check'],['dictationKeepAudioHours','Keep audio (hours; 0 = forever)','number'],['dictationVocabulary','Vocabulary','text'],['dictationPrompt','Cleanup prompt','text']]) {
  const label = document.createElement('label'); label.textContent = title; const input = document.createElement(Array.isArray(type) ? 'select' : type === 'text' ? 'textarea' : 'input'); input.className = type === 'text' ? 'nk-textarea' : 'nk-input';
  if (Array.isArray(type)) { const options = key === 'dictationMicUID' ? [{id:'',name:'System default'},...type] : type.map(id => ({id,name:id})); for (const d of options) { const o = document.createElement('option'); o.value = d.id; o.textContent = d.name; input.append(o); } }
  if (type === 'check') { input.type = 'checkbox'; input.checked = !!p[key]; label.className = 'check'; } else { input.value = p[key] ?? ''; if (type === 'number') { input.type = 'number'; input.min = '0'; } }
  input.onchange = () => set(key,type === 'check' ? input.checked : type === 'number' ? Math.max(0,Number(input.value)) : input.value); label.append(input); $('fields').append(label);
 }
 for (const mode of ['hold','toggle']) { const b = document.createElement('button'); b.className = 'nk-btn'; b.textContent = 'Record ' + mode + ' shortcut'; b.onclick = async () => { try { b.textContent = 'Press keys… (Delete turns off)'; const value = await nook.host.call('hotkeys.record',{id:mode,modifierOnly:true}); await nook.native.call('dictation.shortcut',{mode,value}); b.textContent = mode + ': ' + (value?.display || 'Off'); } catch(e) { error(e); b.textContent = 'Record ' + mode + ' shortcut'; } }; $('fields').append(b); }
 const note = document.createElement('p'); note.className = 'hint'; note.textContent = 'Recordings stay in private plugin data. Audio is sent to ChatGPT or Groq for transcription; cleanup uses your Groq key. Failed recordings remain retryable for at least seven days. Manage shared provider keys in ChatGPT & Codex Settings.'; $('fields').append(note);
 } catch(e) { error(e); } }
$('reload').onclick = load; nook.native.on('ready',load); load();
})();
