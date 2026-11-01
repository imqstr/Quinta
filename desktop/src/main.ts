import './style.css';
import { onEvent, request } from './bridge';
import { getCurrentWindow } from '@tauri-apps/api/window';

type Route = 'play' | 'settings' | 'studio' | 'mods' | 'logs' | 'info';
type Settings = Record<string, string | number | boolean | string[]>;
type Snapshot = {
  version: string; clientVersion: string | null; settings: Settings;
  runtime: { runtime: string; executable: string; prefix: string; sysroot: string } | null;
  runtimeError: string | null; gpus: { id: string; name: string; memory_mib: number }[];
  session: { kind: string; seconds: number; pid: number } | null; busy: boolean;
  canLaunch: boolean; readiness: string | null; source: string; data: string; logs: string;
  shimsReady: boolean; studioInstalled: boolean; backend: string;
  mods: { name: string; enabled: boolean; path: string }[]; fastFlags: Record<string, unknown>;
};
const iconNames: Record<string, string> = {
  play: 'media-playback-start', settings: 'emblem-system', studio: 'applications-development',
  mods: 'application-x-addon', logs: 'utilities-terminal', info: 'help-about',
  refresh: 'view-refresh', open: 'adw-external-link', folder: 'folder-open',
  more: 'open-menu', close: 'window-close', download: 'folder-download',
  graphics: 'video-display', network: 'quinta-web', check: 'emblem-ok', code: 'quinta-github',
  chevron: 'go-next', back: 'go-previous', search: 'edit-find', clock: 'preferences-system-time', stop: 'edit-clear', copy: 'edit-copy',
  minimize: 'window-minimize', maximize: 'window-maximize',
};
function icon(name: string, cls = '') { return `<span class="icon ${cls}" aria-hidden="true" style="--icon:url('/icons/${iconNames[name] || name}-symbolic.svg')"></span>`; }
function escape(value: unknown) { return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!)); }
let state: Snapshot | null = null;
let route: Route = 'play';
let tab = 'general';
let operation = false;
let logTimer: ReturnType<typeof setInterval> | undefined;
let toastTimer: ReturnType<typeof setTimeout>;
let saveSequence = 0;
let clientIcon: string | null = null;
const themes: [string, string, string][] = [['blue', 'Blue', '#0a84ff'], ['purple', 'Purple', '#a550a7'], ['pink', 'Pink', '#f74f9e'], ['red', 'Red', '#ff5257'], ['orange', 'Orange', '#f7821b'], ['yellow', 'Yellow', '#ffc600'], ['green', 'Green', '#62ba46'], ['graphite', 'Graphite', '#8c8c8c']];
function readTheme() { try { return localStorage.getItem('quinta-accent') || 'blue'; } catch { return 'blue'; } }
function applyTheme(name: string) {
  document.documentElement.dataset.theme = name;
  try { localStorage.setItem('quinta-accent', name); } catch { /* storage unavailable */ }
  window.dispatchEvent(new Event('quinta-theme'));
}
applyTheme(readTheme());
const tints: Record<Route, string> = { play: '#34c759', settings: '#5856d6', studio: '#0a84ff', mods: '#ff9500', logs: '#30b0c7', info: '#af52de' };
const routeIcons: Record<Route, string> = { play: 'play', settings: 'settings', studio: 'studio', mods: 'mods', logs: 'logs', info: 'info' };
const titles: Record<Route, string> = { play: 'Play', settings: 'Settings', studio: 'Studio', mods: 'Mods', logs: 'Logs', info: 'Info' };
const app = document.querySelector<HTMLDivElement>('#app')!;
app.innerHTML = `
<div class="window-shell">
  <aside class="sidebar" data-drag>
    <div class="traffic-lights"><button class="light close" data-window="close" aria-label="Close"></button><button class="light minimize" data-window="minimize" aria-label="Minimize"></button><button class="light zoom" data-window="maximize" aria-label="Zoom"></button></div>
    <label class="sidebar-search">${icon('search')}<input id="sidebar-search" type="search" placeholder="Search" aria-label="Search sections"></label>
    <div class="sidebar-account"><img class="brand-mark" src="/quinta-mark.png" alt="" aria-hidden="true"><div><strong>Quinta</strong><small id="sidebar-version">0.1.0</small></div></div>
    <nav aria-label="Main navigation">${(['play', 'settings', 'studio', 'mods', 'logs', 'info'] as Route[]).map(name => `<button class="nav-item${name === 'settings' || name === 'logs' ? ' section-start' : ''}" data-route="${name}"><span class="squircle" style="--tint:${tints[name]}">${icon(routeIcons[name])}</span><span>${titles[name]}</span></button>`).join('')}</nav>
  </aside>
  <div class="workspace">
    <header class="toolbar" data-drag><div class="history"><button class="history-button" data-history="back" aria-label="Back">${icon('back')}</button><button class="history-button" data-history="forward" aria-label="Forward">${icon('chevron')}</button></div><h1 id="page-title">Play</h1></header>
    <div class="scroll-area"><main id="content" tabindex="-1"></main></div>
    <div id="progress" class="task-progress" hidden><span id="progress-label"></span><span id="progress-value"></span><div class="progress-track"><div id="progress-fill"></div></div></div>
  </div>
</div>
<div id="toast" class="toast" role="status" aria-live="polite" hidden></div>
<dialog id="quit-dialog"><h2>Quit Quinta?</h2><p>A client or background operation is still running. Quitting will stop it.</p><div class="dialog-actions"><button data-action="cancel-quit">Keep open</button><button class="danger-button" data-action="confirm-quit">Quit Quinta</button></div></dialog>`;
const content = document.querySelector<HTMLElement>('#content')!;

function setting(key: string) { return state?.settings[key]; }
function hours(seconds: number) { if (seconds < 3600) return `${Math.floor(seconds / 60)} min`; return `${Math.floor(seconds / 3600)} hr ${Math.floor(seconds % 3600 / 60)} min`; }
function renderer() { return ({ opengl: 'OpenGL', vulkan: 'Vulkan / Zink', metal: 'Metal' } as Record<string, string>)[String(setting('renderer'))] || 'OpenGL'; }
function dnsName() { return ({ quad9: 'Quad9', cloudflare: 'Cloudflare', google: 'Google', system: 'System DNS', custom: String(setting('dns_custom') || 'Custom') } as Record<string, string>)[String(setting('dns'))] || 'Quad9'; }
function activeGpu() { return state?.gpus.find(g => g.id === setting('gpu'))?.name || (setting('gpu') === 'auto' ? 'Automatic' : 'Dedicated graphics'); }
function button(action: string, label: string, glyph?: string, cls = '') { return `<button data-action="${action}" class="${cls}" ${operation ? 'disabled' : ''}>${glyph ? icon(glyph) : ''}<span>${label}</span></button>`; }
function select(key: string, label: string, options: [string, string][], description = '') {
  return `<label class="setting-row" for="${key}"><span class="setting-copy"><strong>${label}</strong>${description ? `<small>${description}</small>` : ''}</span><select id="${key}" data-setting="${key}">${options.map(([value, text]) => `<option value="${escape(value)}" ${String(setting(key)) === value ? 'selected' : ''}>${escape(text)}</option>`).join('')}</select></label>`;
}
function toggle(key: string, label: string, description = '') { return `<label class="setting-row" for="${key}"><span class="setting-copy"><strong>${label}</strong>${description ? `<small>${description}</small>` : ''}</span><input id="${key}" data-setting="${key}" class="switch" type="checkbox" role="switch" ${setting(key) ? 'checked' : ''}></label>`; }
function numberField(key: string, label: string, min: number, max: number, step: number, suffix = '') { return `<label class="setting-row" for="${key}"><span class="setting-copy"><strong>${label}</strong></span><span class="number-control"><input id="${key}" data-setting="${key}" type="number" min="${min}" max="${max}" step="${step}" value="${escape(setting(key))}">${suffix ? `<span>${suffix}</span>` : ''}</span></label>`; }
function group(title: string, rows: string, description = '') { return `<section class="settings-group"><div class="section-heading"><h2>${title}</h2>${description ? `<p>${description}</p>` : ''}</div><div class="settings-list">${rows}</div></section>`; }
// Tahoe panes carry no header: the toolbar shows the title. Actions sit above the first group.
function heading(_title: string, _subtitle = '', actions = '') { return actions ? `<div class="pane-actions">${actions}</div>` : ''; }

function playPage() {
  const running = !!state?.session;
  const launchLabel = running ? 'Stop' : operation ? 'Working…' : !state?.clientVersion ? 'Install' : 'Play';
  const action = running ? 'stop' : !state?.clientVersion ? 'update' : !state?.canLaunch ? 'setup' : 'launch';
  const status = running ? 'Running' : state?.clientVersion ? `Version ${escape(state.clientVersion)}` : 'Not installed';
  const cap = Number(setting('framerate_cap') || 0);
  const row = (target: string, glyph: string, tint: string, label: string, value: string) => `<button class="list-row" ${target}><span class="squircle" style="--tint:${tint}">${icon(glyph)}</span><span class="row-label">${label}</span><span class="row-value">${escape(value)}</span>${icon('chevron', 'row-chevron')}</button>`;
  return `<section class="app-card">
      <div class="app-icon${clientIcon ? ' has-image' : ''}" aria-hidden="true">${clientIcon ? `<img src="${clientIcon}" alt="">` : '<svg viewBox="0 0 100 100"><path fill="currentColor" fill-rule="evenodd" d="M24 10 90 26 74 90 8 74ZM42 38 38 58 58 62 62 42Z"/></svg>'}</div>
      <div class="app-text"><h2>Roblox</h2><p class="app-meta"><span>${icon(running ? 'play' : 'check')}${status}</span>${running ? '' : `<span>${icon('clock')}${hours(Number(setting('playtime_seconds') || 0))} played</span>`}</p></div>
      <div class="app-actions client-meta">${button('check-update', 'Check for Updates')}${button(action, launchLabel, undefined, running ? '' : 'primary-button')}</div>
    </section>
    <section class="settings-group"><h3 class="group-title">Launch Setup</h3><div class="settings-list">
      ${row('data-settings-tab="graphics"', 'graphics', '#0a84ff', 'Renderer', renderer())}
      ${row('data-settings-tab="graphics"', 'settings', '#ff9500', 'Graphics Card', activeGpu())}
      ${row('data-settings-tab="network"', 'network', '#34c759', 'DNS Resolver', dnsName())}
      ${row('data-settings-tab="graphics"', 'clock', '#ff2d55', 'Frame Rate', cap > 0 ? `${cap} FPS` : 'Roblox default')}
    </div></section>
    <section class="settings-group"><div class="settings-list">
      ${row('data-action="view-logs"', 'logs', '#30b0c7', 'Launch Logs', 'Latest')}
    </div></section>`;
}
function settingsPage() {
  const tabs = [['general', 'General'], ['graphics', 'Graphics'], ['network', 'Network'], ['advanced', 'Advanced']];
  let body = '';
  // One page with every category; the segments scroll to a category.
  const all = true, category = (name: string) => `<h2 class="category-title" id="category-${name.toLowerCase()}">${name}</h2>`;
  if (all || tab === 'general') body += category('General') + group('Appearance', `<div class="setting-row"><span class="setting-copy"><strong>Accent colour</strong></span><div class="theme-picker" role="group" aria-label="Accent colour">${themes.map(([id, name, color]) => `<button class="theme-swatch" data-theme-choice="${id}" aria-label="${name}" title="${name}" aria-pressed="${readTheme() === id}" style="--swatch:${color}"></button>`).join('')}</div></div>`) + group('Client', toggle('raw_mouse', 'Raw mouse input', 'Use direct mouse motion for camera controls.') + numberField('mouse_sensitivity', 'Mouse sensitivity', 0.1, 10, 0.1) + numberField('scroll_sensitivity', 'Scroll sensitivity', 0.1, 10, 0.1)) + group('Launcher', toggle('hide_launcher_on_launch', 'Hide Quinta while playing') + toggle('show_launcher_after_exit', 'Show Quinta when Roblox closes') + toggle('auto_patch_throttle', 'Apply startup compatibility repair', 'Keeps supported clients from starting with a slow render loop.'));
  if (all || tab === 'graphics') {
    const gpus: [string, string][] = [['auto', 'Automatic'], ...(state?.gpus.map(g => [g.id, g.name] as [string, string]) || [])];
    if (setting('gpu') !== 'auto' && !gpus.some(([id]) => id === setting('gpu'))) gpus.push([String(setting('gpu')), 'Selected graphics card']);
    body += category('Graphics') + group('Rendering', select('renderer', 'Renderer', [['opengl', 'OpenGL'], ['vulkan', 'Vulkan / Zink'], ['metal', 'Metal · experimental']]) + select('gpu', 'Graphics card', gpus) + select('display_backend', 'Window system', [['wayland', 'Wayland'], ['x11', 'X11 / Xwayland']])) + group('Display', numberField('framerate_cap', 'Frame rate limit', 0, 1000, 1, 'FPS') + numberField('dpi_scale', 'Interface scale', 1, 4, 0.25, '×'), 'Set the frame rate to 0 to use Roblox’s default.');
  }
  if (all || tab === 'network') body += category('Network') + group('DNS resolver', select('dns', 'DNS provider', [['quad9', 'Quad9'], ['cloudflare', 'Cloudflare'], ['google', 'Google'], ['system', 'System DNS'], ['custom', 'Custom']]) + (setting('dns') === 'custom' ? `<label class="setting-row" for="dns_custom"><span class="setting-copy"><strong>Custom server</strong><small>IP address, optionally followed by :port.</small></span><input id="dns_custom" data-setting="dns_custom" type="text" value="${escape(setting('dns_custom'))}" placeholder="9.9.9.9:53"></label>` : ''), 'Only the Roblox client uses this resolver. Your system settings stay as they are.');
  if (all || tab === 'advanced') body += category('Advanced') + group('Diagnostics', toggle('diagnostic_signals', 'Crash diagnostics') + toggle('trace_gl', 'OpenGL tracing') + toggle('trace_udp', 'Network tracing') + numberField('keep_logs', 'Launch logs to keep', 1, 100, 1), 'Enable detailed tracing while investigating a problem.') + `<section class="settings-group"><div class="section-heading"><h2>Client flags</h2><span class="muted">Applies on next launch</span></div><textarea id="flags-editor" class="code-editor" spellcheck="false" aria-label="Client flags JSON">${escape(JSON.stringify(state?.fastFlags || {}, null, 2))}</textarea><div class="editor-actions">${button('save-flags', 'Save flags', 'check')}</div></section>` + runtimeForm();
  return `${heading('Settings', 'Set up the client the way you play.', '<span id="save-status" class="save-status">Changes save automatically</span>')}<div class="segmented-tabs" role="tablist" aria-label="Settings categories">${tabs.map(([id, title]) => `<button role="tab" aria-selected="${tab === id}" data-tab="${id}">${title}</button>`).join('')}</div><div class="settings-content">${body}</div>`;
}
function runtimeForm() { const runtime = state?.runtime; return `<section class="settings-group"><div class="section-heading"><h2>Runtime</h2><span class="muted">CiderDarling or Darling</span></div><form id="runtime-form" class="runtime-form"><label>Executable<input name="executable" required value="${escape(runtime?.executable || '')}" placeholder="/opt/ciderdarling/…/bin/darling"></label><label>System root<input name="sysroot" required value="${escape(runtime?.sysroot || '')}" placeholder="/opt/ciderdarling/…/libexec/darling"></label><label>Prefix<input name="prefix" required value="${escape(runtime?.prefix || '')}" placeholder="/home/you/.ciderdarling"></label><button type="submit">Save runtime</button></form><div class="inline-actions">${button('build-shims', 'Build native shims', 'code')}${button('open-config', 'Open settings folder', 'folder')}</div></section>`; }
function modsPage() { return `${heading('Mods', 'Custom client resources.', button('open-mods', 'Open mods folder', 'folder'))}${group('Custom modifications', toggle('enable_custom_mods', 'Enable custom mods', 'Changes apply the next time you launch Roblox.'))}${state?.mods.length ? `<div class="settings-list">${state.mods.map(mod => `<label class="setting-row"><span class="setting-copy"><strong>${escape(mod.name)}</strong><small>Custom resource folder</small></span><input type="checkbox" role="switch" class="switch" data-mod="${escape(mod.name)}" ${mod.enabled ? 'checked' : ''}></label>`).join('')}</div>` : `<section class="empty-state">${icon('mods')}<h2>No custom mods yet</h2><p>Add a folder inside your modifications directory. Its files should follow Roblox’s resource layout.</p>${button('open-mods', 'Open mods folder', 'folder')}</section>`}`; }
function studioPage() { return `${heading('Roblox Studio', 'The native macOS client through CiderDarling.')}<section class="studio-notice">${icon('info')}<div><strong>Experimental startup</strong><p>This runtime currently reaches Qt window creation, then exits. The experiment is available for diagnosis; it is not a working editor yet.</p></div></section><section class="client-card compact"><div class="client-card-main"><div class="app-symbol">${icon('studio')}</div><div class="client-identity"><h2>Roblox Studio</h2><div class="client-status">${state?.studioInstalled ? 'Intel macOS build installed' : 'macOS Studio bundle is not installed'}</div></div></div><div class="client-card-actions"><button class="quiet-button" data-action="view-logs">${icon('logs')}View logs</button><button class="secondary-button" data-action="launch-studio" ${!state?.studioInstalled || operation ? 'disabled' : ''}>${icon('play')}Test startup</button></div></section>`; }
function logsPage() { return `${heading('Launch logs', 'Recent output from the selected client.', `<div class="button-group">${button('refresh-logs', 'Refresh', 'refresh')}${button('open-logs', 'Open folder', 'folder')}</div>`)}<div class="log-shell"><div class="log-toolbar"><span class="status-dot"></span><span id="log-filename">Latest launch</span><button class="icon-button" data-action="copy-logs" aria-label="Copy log">${icon('copy')}</button></div><pre id="log-output" tabindex="0" aria-label="Launch log">Loading log…</pre></div>`; }
function infoPage() { return `<section class="about-identity"><img class="brand-mark large" src="/quinta-mark.png" alt=""><div><h2>Quinta <span>${escape(state?.version || '0.1.0')}</span></h2><p>Built on <button class="inline-link" data-action="open-upstream">Quadra</button>.</p></div></section><p class="about-description">A launcher for running the macOS Roblox client on Linux through Darling. Quinta is independent of Roblox Corporation.</p><div class="about-links">${button('open-source', 'Source code', 'code')}${button('report', 'Report a problem', 'open')}${button('open-license', 'License', 'open')}</div><section class="about-credits"><h2>Acknowledgments</h2><p>Built on the work of the upstream launcher contributors, Darling, CiderDarling and the native compatibility projects. Google Material Symbols are distributed under Apache 2.0. Original license notices are retained in the repository.</p></section>`; }

function render() {
  const focused = document.activeElement as HTMLInputElement | null;
  const focusedId = focused?.id;
  document.title = `${titles[route]} · Quinta`;
  document.querySelector('#page-title')!.textContent = route === 'info' ? 'About' : titles[route];
  document.querySelectorAll<HTMLButtonElement>('[data-route]').forEach(button => { const selected = button.dataset.route === route; button.classList.toggle('selected', selected); if (selected) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current'); });
  document.querySelector('#sidebar-version')!.textContent = `v${state?.version || '0.1.0'}`;
  if (!state) content.innerHTML = `${heading('Quinta')}<div class="loading-state"><span class="spinner"></span>Connecting to the desktop backend…</div>`;
  else content.innerHTML = ({ play: playPage, settings: settingsPage, studio: studioPage, mods: modsPage, logs: logsPage, info: infoPage })[route]();
  if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
}
function moveIndicator(_animate = true) { /* sidebar selection is static */ }
type SearchEntry = { label: string; path: string; route: Route; tab?: string; target?: string; words: string };
const searchIndex: SearchEntry[] = [
  { label: 'Accent colour', path: 'Settings › General', route: 'settings', tab: 'general', words: 'theme color colour appearance accent' },
  { label: 'Raw mouse input', path: 'Settings › General', route: 'settings', tab: 'general', target: 'raw_mouse', words: 'mouse raw input camera' },
  { label: 'Mouse sensitivity', path: 'Settings › General', route: 'settings', tab: 'general', target: 'mouse_sensitivity', words: 'mouse sensitivity speed dpi' },
  { label: 'Scroll sensitivity', path: 'Settings › General', route: 'settings', tab: 'general', target: 'scroll_sensitivity', words: 'scroll wheel zoom sensitivity' },
  { label: 'Hide Quinta while playing', path: 'Settings › General', route: 'settings', tab: 'general', target: 'hide_launcher_on_launch', words: 'launcher hide window' },
  { label: 'Show Quinta when Roblox closes', path: 'Settings › General', route: 'settings', tab: 'general', target: 'show_launcher_after_exit', words: 'launcher show reopen' },
  { label: 'Startup compatibility repair', path: 'Settings › General', route: 'settings', tab: 'general', target: 'auto_patch_throttle', words: 'patch throttle repair startup fix' },
  { label: 'Renderer', path: 'Settings › Graphics', route: 'settings', tab: 'graphics', target: 'renderer', words: 'renderer vulkan opengl metal zink graphics api' },
  { label: 'Graphics card', path: 'Settings › Graphics', route: 'settings', tab: 'graphics', target: 'gpu', words: 'gpu graphics card nvidia amd vram' },
  { label: 'Window system', path: 'Settings › Graphics', route: 'settings', tab: 'graphics', target: 'display_backend', words: 'wayland x11 xwayland display window' },
  { label: 'Frame rate limit', path: 'Settings › Graphics', route: 'settings', tab: 'graphics', target: 'framerate_cap', words: 'fps frame rate cap limit unlock 240 144' },
  { label: 'Interface scale', path: 'Settings › Graphics', route: 'settings', tab: 'graphics', target: 'dpi_scale', words: 'scale dpi ui size hidpi' },
  { label: 'DNS provider', path: 'Settings › Network', route: 'settings', tab: 'network', target: 'dns', words: 'dns network quad9 cloudflare google resolver internet' },
  { label: 'Client flags (FFlags)', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'flags-editor', words: 'fflags fflag fast flags fastflags clientappsettings dfint fint flag json' },
  { label: 'Crash diagnostics', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'diagnostic_signals', words: 'crash debug diagnostics signals' },
  { label: 'OpenGL tracing', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'trace_gl', words: 'opengl gl trace debug' },
  { label: 'Network tracing', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'trace_udp', words: 'network udp trace debug' },
  { label: 'Launch logs to keep', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'keep_logs', words: 'logs keep history' },
  { label: 'Runtime (CiderDarling)', path: 'Settings › Advanced', route: 'settings', tab: 'advanced', target: 'runtime-form', words: 'runtime darling ciderdarling prefix sysroot executable shims' },
  { label: 'Custom mods', path: 'Mods', route: 'mods', target: 'enable_custom_mods', words: 'mods modifications textures sounds fonts cursor' },
  { label: 'Roblox Studio', path: 'Studio', route: 'studio', words: 'studio editor build create' },
  { label: 'Launch logs', path: 'Logs', route: 'logs', words: 'logs output console errors' },
  { label: 'About Quinta', path: 'Info', route: 'info', words: 'about version license credits quadra' },
];
// Searches individual settings (macOS-style), not just sidebar sections.
function searchResults(query: string) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const hits = searchIndex.filter(entry => terms.every(term => `${entry.label} ${entry.path} ${entry.words}`.toLowerCase().includes(term)));
  if (!hits.length) return `<section class="empty-state">${icon('search')}<h2>No Results</h2><p>Nothing matches “${escape(query)}”.</p></section>`;
  return `<section class="settings-group"><h3 class="group-title">Search Results</h3><div class="settings-list">${hits.map(entry =>
    `<button class="list-row" data-hit-route="${entry.route}" data-hit-tab="${entry.tab || ''}" data-hit-target="${entry.target || ''}"><span class="squircle" style="--tint:${tints[entry.route]}">${icon(routeIcons[entry.route])}</span><span class="row-label">${escape(entry.label)}</span><span class="row-value">${escape(entry.path)}</span>${icon('chevron', 'row-chevron')}</button>`).join('')}</div></section>`;
}
function revealSetting(target: string) {
  const element = document.getElementById(target);
  const row = element?.closest<HTMLElement>('.setting-row, .settings-group, form') || element;
  if (!row) return;
  row.scrollIntoView({ block: 'center', behavior: 'smooth' });
  row.classList.remove('flash'); void row.offsetWidth; row.classList.add('flash');
}
function scrollToCategory(name: string) {
  document.querySelectorAll<HTMLElement>('[data-tab]').forEach(segment => segment.setAttribute('aria-selected', String(segment.dataset.tab === name)));
  document.getElementById(`category-${name}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}
let navToken = 0;
const history: Route[] = []; let future: Route[] = [];
function navigate(next: Route, fromHistory = false) {
  if (next === route && content.childElementCount) return;
  const token = ++navToken;
  if (!fromHistory && route) { history.push(route); future = []; }
  route = next;
  document.querySelectorAll<HTMLButtonElement>('[data-route]').forEach(b => b.classList.toggle('selected', b.dataset.route === route));
  moveIndicator();
  content.classList.add('page-exit');
  setTimeout(() => {
    if (token !== navToken) return;
    content.classList.remove('page-exit', 'page-enter'); render(); void content.offsetWidth; content.classList.add('page-enter');
    setTimeout(() => { if (token === navToken) content.classList.remove('page-enter'); }, 900);
    document.querySelector('.scroll-area')!.scrollTop = 0;
  }, 140);
  if (logTimer) clearInterval(logTimer); logTimer = undefined;
  if (route === 'logs') { setTimeout(() => void loadLogs(), 160); if (state?.session) logTimer = setInterval(() => void loadLogs(), 1500); }
}
function toast(message: string, error = false) { const el = document.querySelector<HTMLElement>('#toast')!; el.textContent = message; el.classList.toggle('error', error); el.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.hidden = true; }, error ? 8000 : 3500); }
async function refresh() { state = await request<Snapshot>('get_snapshot'); if (clientIcon === null) clientIcon = await request<string | null>('client_icon').catch(() => null) || ''; render(); }
async function save(patch: Record<string, unknown>) { const sequence = ++saveSequence; try { const settings = await request<Settings>('save_settings', { patch }); if (state && sequence === saveSequence) { state.settings = settings; if ('dns' in patch) render(); const saved = document.querySelector('#save-status'); if (saved) saved.textContent = 'Saved'; } } catch (e) { toast(String(e), true); render(); } }
async function loadLogs() { try { const result = await request<{ path: string | null; text: string }>('read_logs'); const output = document.querySelector<HTMLElement>('#log-output'); if (output) { const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 60; output.textContent = result.text; if (atBottom) output.scrollTop = output.scrollHeight; } const title = document.querySelector('#log-filename'); if (title) title.textContent = result.path?.split('/').pop() || 'No launches yet'; } catch (e) { toast(String(e), true); } }
async function task(command: string, args?: Record<string, unknown>, success?: string) { if (operation) return; operation = true; render(); try { const result = await request<unknown>(command, args); if (success) toast(success); await refresh(); return result; } catch (e) { toast(String(e), true); } finally { operation = false; document.querySelector<HTMLElement>('#progress')!.hidden = true; render(); } }
function external(url: string) { return request('open_external', { url }).catch(e => toast(String(e), true)); }

const actions: Record<string, () => unknown> = {
  launch: () => task('launch_client', { kind: 'player' }), 'launch-studio': () => task('launch_client', { kind: 'studio' }), stop: () => task('stop_client'),
  update: () => task('update_client', undefined, 'Roblox is installed and up to date.'),
  setup: () => { tab = 'advanced'; navigate('settings'); }, 'view-logs': () => navigate('logs'), 'refresh-logs': loadLogs,
  'check-update': async () => { try { const result = await request<{ version: string }>('check_client_update'); toast(result.version === state?.clientVersion ? 'Roblox is up to date.' : `Roblox ${result.version} is available. Install it in Settings.`); if (result.version !== state?.clientVersion) { document.querySelector('.client-meta')?.insertAdjacentHTML('beforeend', button('update', 'Install update', 'download')); } } catch (e) { toast(String(e), true); } },
  'open-mods': () => request('open_location', { location: 'mods' }), 'open-logs': () => request('open_location', { location: 'logs' }), 'open-config': () => request('open_location', { location: 'config' }),
  'open-source': () => external('https://github.com/imqstr/Quinta'), 'open-upstream': () => external('https://github.com/QuadraHQ/Quadra'), report: () => external('https://github.com/imqstr/Quinta/issues'), 'open-license': () => external('https://github.com/imqstr/Quinta/blob/main/LICENSE'),
  'build-shims': () => task('build_shims', undefined, 'Native compatibility shims rebuilt.'),
  'save-flags': async () => { try { const flags = JSON.parse((document.querySelector('#flags-editor') as HTMLTextAreaElement).value); await task('save_fast_flags', { flags }, 'Client flags saved.'); } catch (e) { toast(`Invalid JSON: ${e}`, true); } },
  'copy-logs': async () => { await navigator.clipboard.writeText(document.querySelector('#log-output')?.textContent || ''); toast('Log copied.'); },
  'cancel-quit': () => (document.querySelector('#quit-dialog') as HTMLDialogElement).close(), 'confirm-quit': () => request('quit_app'),
};
app.addEventListener('click', event => {
  const target = (event.target as HTMLElement).closest<HTMLElement>('button'); if (!target || target.matches(':disabled')) return;
  if (target.dataset.hitRoute) {
    (document.querySelector('#sidebar-search') as HTMLInputElement).value = '';
    if (target.dataset.hitTab) tab = target.dataset.hitTab;
    const destination = target.dataset.hitTarget;
    route = '' as Route; navigate(target.dataset.hitRoute as Route);
    if (destination) setTimeout(() => revealSetting(destination), 340);
    return;
  }
  if (target.dataset.history) {
    const stack = target.dataset.history === 'back' ? history : future, other = target.dataset.history === 'back' ? future : history;
    const next = stack.pop(); if (next) { other.push(route); navigate(next, true); }
    return;
  }
  if (target.dataset.themeChoice) { applyTheme(target.dataset.themeChoice); document.querySelectorAll<HTMLElement>('[data-theme-choice]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.themeChoice === target.dataset.themeChoice))); }
  else if (target.dataset.route) navigate(target.dataset.route as Route);
  else if (target.dataset.tab) { tab = target.dataset.tab; scrollToCategory(tab); }
  else if (target.dataset.settingsTab) { tab = target.dataset.settingsTab; const goal = tab; navigate('settings'); setTimeout(() => scrollToCategory(goal), 200); }
  else if (target.dataset.window) void request('window_action', { action: target.dataset.window }).catch(e => toast(String(e), true));
  else if (target.dataset.action && actions[target.dataset.action]) Promise.resolve(actions[target.dataset.action]()).catch(e => toast(String(e), true));
});
app.addEventListener('pointerdown', event => { const target = event.target as HTMLElement; if (event.button === 0 && target.closest('[data-drag]') && !target.closest('button')) void request('window_action', { action: 'drag' }); });
app.addEventListener('change', event => {
  const target = event.target as HTMLInputElement | HTMLSelectElement;
  if (target.dataset.setting) { const value = target.type === 'checkbox' ? (target as HTMLInputElement).checked : target.type === 'number' ? Number(target.value) : target.value; void save({ [target.dataset.setting]: value }); }
  else if ((target as HTMLInputElement).dataset.mod && state) { const name = target.dataset.mod!; const enabled = new Set(state.settings.enabled_mods as string[] || []); if ((target as HTMLInputElement).checked) enabled.add(name); else enabled.delete(name); void save({ enabled_mods: [...enabled] }); }
});
app.addEventListener('submit', event => { if ((event.target as HTMLElement).id !== 'runtime-form') return; event.preventDefault(); const data = new FormData(event.target as HTMLFormElement); const selection = { runtime: state?.runtime?.runtime || 'ciderdarling', executable: data.get('executable'), sysroot: data.get('sysroot'), prefix: data.get('prefix') }; void task('save_runtime', { selection }, 'Runtime selection saved.'); });
document.addEventListener('keydown', event => { if ((event.ctrlKey || event.metaKey) && /^[1-6]$/.test(event.key)) { event.preventDefault(); navigate((['play', 'settings', 'studio', 'mods', 'logs', 'info'] as Route[])[Number(event.key) - 1]); } });
render();
// No browser context menu (Inspect, Reload); text fields keep theirs for copy/paste.
document.addEventListener('contextmenu', event => { if (!(event.target as HTMLElement).closest('input, textarea, pre')) event.preventDefault(); });
document.querySelector<HTMLInputElement>('#sidebar-search')!.addEventListener('input', event => {
  const query = (event.target as HTMLInputElement).value.trim();
  document.querySelector('#page-title')!.textContent = query ? 'Search' : (route === 'info' ? 'About' : titles[route]);
  document.querySelectorAll<HTMLElement>('.nav-item').forEach(item => item.classList.toggle('selected', !query && item.dataset.route === route));
  if (query) { content.innerHTML = searchResults(query); content.classList.remove('page-enter'); void content.offsetWidth; content.classList.add('page-enter'); }
  else render();
});
requestAnimationFrame(() => moveIndicator(false));
window.addEventListener('resize', () => moveIndicator(false));
// Rounded corners only while floating; a maximized window meets the screen edges.
async function syncMaximized() { try { document.documentElement.classList.toggle('maximized', await getCurrentWindow().isMaximized()); } catch { /* browser preview */ } }
window.addEventListener('resize', () => void syncMaximized());
void syncMaximized();
void (async () => {
  try {
    await Promise.all([
      onEvent('hardware-ready', () => void refresh()),
      onEvent<{ running: boolean; earlyExit?: boolean }>('session-changed', event => { void refresh(); if (event.earlyExit) toast('The client exited during startup. Check Launch logs for details.', true); }),
      onEvent<{ label: string; percent: number }>('task-progress', event => { const progress = document.querySelector<HTMLElement>('#progress')!; progress.hidden = false; document.querySelector('#progress-label')!.textContent = event.label; document.querySelector('#progress-value')!.textContent = `${Math.round(event.percent * 100)}%`; (document.querySelector('#progress-fill') as HTMLElement).style.transform = `scaleX(${event.percent})`; }),
      onEvent('close-requested', () => (document.querySelector('#quit-dialog') as HTMLDialogElement).showModal()),
    ]);
    await refresh();
  } catch (e) { content.innerHTML = `${heading('Desktop connection unavailable')}<div class="error-panel"><p>Open Quinta from its desktop launcher to connect to the Rust backend.</p><pre>${escape(String(e))}</pre></div>`; }
})();
