/* Papers Coordination Dashboard — read-only local client.
 * Polls /api/status and the incremental per-member + BRAIN streams with
 * byte-offset cursors, appending only new lines and keeping bounded buffers. */

const STATUS_MS = 2000;
const STREAM_MS = 2000;
const MAX_STREAM_LINES = 80;

const columns = document.getElementById('columns');
const members = ['winter', 'gazelle', 'roketpuncha', 'ning'];
const memberEmoji = { winter: '❄️', gazelle: '🦌', roketpuncha: '🚀', ning: '🐉' };
const state = {};
const BOTTOM_TOLERANCE_PX = 3;

function minuteTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

function initColumns() {
  columns.replaceChildren();
  for (const key of members) {
    const card = el('section', 'member');
    card.id = 'member-' + key;
    const header = el('header');
    header.append(el('h3', null, `${memberEmoji[key]} ${key.charAt(0).toUpperCase() + key.slice(1)}`));
    header.append(el('div', 'member-state', '—'));
    header.append(el('div', 'report', 'report: —'));
    header.append(el('div', 'mailbox', ''));
    header.append(el('div', 'last-write', 'last write —'));
    // Native OpenCode reasoning is a sequence of independently updated parts,
    // not a terminal transcript.  A div lets us preserve each exact part while
    // reconciling an in-progress part by its stable database id.
    const stream = el('div', 'stream reasoning-stream', '[idle]');
    stream.id = 'stream-' + key;
    stream.addEventListener('scroll', () => { setFollowState(stream, isAtEnd(stream)); }, { passive: true });
    card.append(header, stream);
    const jump = el('button', 'jump-end hidden', '↓');
    jump.type = 'button';
    jump.dataset.for = stream.id;
    jump.title = 'Jump to live end';
    jump.setAttribute('aria-label', 'Jump ' + key + ' feed to live end');
    const wrap = el('div', 'stream-wrap');
    card.removeChild(stream);
    wrap.append(stream, jump);
    card.append(wrap);
    columns.append(card);
    state[key] = { after: 0, lines: [], nativeParts: new Map() };
  }
}

function appendLines(pre, incoming) {
  const lines = incoming.filter((line) => line.trim().length > 0);
  if (lines.length === 0) return;
  const followLive = isAtEnd(pre);
  if (pre.textContent === '[idle]' || pre.textContent === '[BRAIN run stream idle]' || pre.textContent === '[BRAIN reasoning idle]') pre.textContent = '';
  const all = (pre.textContent.split('\n')).concat(lines);
  const bounded = all.slice(-MAX_STREAM_LINES);
  pre.textContent = bounded.join('\n');
  if (followLive) pre.scrollTop = pre.scrollHeight;
}

function isAtEnd(container) {
  return container.scrollHeight - container.scrollTop - container.clientHeight <= BOTTOM_TOLERANCE_PX;
}

function setFollowState(container, follows) {
  container.dataset.followLive = String(follows);
  const jump = document.querySelector(`.jump-end[data-for="${container.id}"]`);
  if (jump) jump.classList.toggle('hidden', follows);
}

function renderNativeReasoning(container, parts) {
  // The follow state becomes true again as soon as you intentionally
  // wheel/pan to the end of the feed.
  const followLive = container.dataset.followLive === undefined
    ? isAtEnd(container)
    : container.dataset.followLive === 'true';
  setFollowState(container, followLive);
  if (!parts.length) {
    container.textContent = '[native reasoning has not started]';
    return;
  }
  const existing = new Map(Array.from(container.querySelectorAll('[data-part-id]')).map((node) => [node.dataset.partId, node]));
  for (const part of parts) {
    let block = existing.get(part.id);
    const isNew = !block;
    if (!block) {
      block = el('article');
      block.dataset.partId = part.id;
    }
    block.className = 'reasoning-part ' + (part.kind || 'reasoning') + (part.active ? ' active' : '');
    if (part.kind === 'tool') {
      // Native OpenCode tool metadata, rendered as the same compact action
      // event used in its timeline rather than as a terminal command dump.
      block.replaceChildren();
      const action = el('div', 'tool-action');
      action.append(el('span', 'tool-name', part.tool || 'tool'), el('span', 'tool-status', part.status || 'pending'));
      block.append(action);
      if (part.detail) block.append(el('div', 'tool-detail', part.detail));
    } else {
      // The text remains exact; only its native Markdown structure is styled.
      let text = block.querySelector('.reasoning-text');
      if (!text) {
        block.replaceChildren();
        text = el('div', 'reasoning-text');
        // Historical parts load immediately; a part that is active at this
        // exact poll begins the same quick letter-by-letter reveal as desktop.
        if (part.active) {
          text.dataset.rendered = '';
          revealReasoningDelta(container, text, part.text, true);
        } else {
          text.dataset.rendered = part.text;
          renderMarkdown(text, part.text);
        }
        block.append(text);
      } else if (!isNew) {
        revealReasoningDelta(container, text, part.text, Boolean(part.active));
      }
    }
    container.append(block);
    existing.delete(part.id);
  }
  for (const stale of existing.values()) stale.remove();
  // Match OpenCode's auto-follow behaviour without yanking someone who has
  // scrolled upward to inspect an earlier thought.
  if (followLive) container.scrollTop = container.scrollHeight;
  setFollowState(container, isAtEnd(container));
}

function revealReasoningDelta(container, node, target, active) {
  const rendered = node.dataset.rendered ?? node.textContent;
  if (rendered === target) {
    if (!active && node.dataset.formatted !== 'true') renderMarkdown(node, target);
    return;
  }
  // A rewritten part is not a streaming delta. Show it truthfully at once;
  // new blocks and appends to an active native part reveal progressively.
  if (!active || !target.startsWith(rendered)) {
    node.dataset.rendered = target;
    renderMarkdown(node, target);
    return;
  }
  if (node._revealFrame) cancelAnimationFrame(node._revealFrame);
  let position = rendered.length;
  const reveal = () => {
    position = Math.min(target.length, position + Math.max(1, Math.ceil((target.length - position) / 10)));
    const visible = target.slice(0, position);
    node.textContent = visible;
    node.dataset.rendered = visible;
    delete node.dataset.formatted;
    if (container.dataset.followLive === 'true') container.scrollTop = container.scrollHeight;
    if (position < target.length) node._revealFrame = requestAnimationFrame(reveal);
    else node._revealFrame = 0;
  };
  node._revealFrame = requestAnimationFrame(reveal);
}

// A deliberately small, DOM-only Markdown renderer. No source string is ever
// assigned to innerHTML, so a worker's native reasoning cannot execute markup
// in the dashboard. It covers the vocabulary the OpenCode reasoning UI shows.
function renderMarkdown(root, source) {
  root.replaceChildren();
  root.dataset.formatted = 'true';
  const lines = String(source || '').replace(/\r\n?/g, '\n').split('\n');
  let index = 0;
  const appendParagraph = (paragraph) => {
    if (!paragraph.length) return;
    const p = document.createElement('p');
    paragraph.forEach((line, i) => {
      if (i) p.append(document.createElement('br'));
      appendInline(p, line);
    });
    root.append(p);
  };
  while (index < lines.length) {
    if (!lines[index].trim()) { index++; continue; }
    const fence = lines[index].match(/^```([^\s]*)\s*$/);
    if (fence) {
      const code = []; index++;
      while (index < lines.length && !/^```\s*$/.test(lines[index])) code.push(lines[index++]);
      if (index < lines.length) index++;
      const pre = document.createElement('pre');
      const codeNode = document.createElement('code');
      if (fence[1]) codeNode.dataset.language = fence[1];
      codeNode.textContent = code.join('\n'); pre.append(codeNode); root.append(pre); continue;
    }
    const heading = lines[index].match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const h = document.createElement('h' + heading[1].length); appendInline(h, heading[2]); root.append(h); index++; continue;
    }
    if (/^>\s?/.test(lines[index])) {
      const quote = document.createElement('blockquote');
      while (index < lines.length && /^>\s?/.test(lines[index])) {
        appendInline(quote, lines[index].replace(/^>\s?/, '')); quote.append(document.createElement('br')); index++;
      }
      quote.lastChild?.remove(); root.append(quote); continue;
    }
    const listMatch = lines[index].match(/^(?:[-*+]\s+|\d+\.\s+)(.*)$/);
    if (listMatch) {
      const ordered = /^\d+\.\s+/.test(lines[index]);
      const list = document.createElement(ordered ? 'ol' : 'ul');
      const pattern = ordered ? /^\d+\.\s+(.*)$/ : /^[-*+]\s+(.*)$/;
      while (index < lines.length) {
        const item = lines[index].match(pattern); if (!item) break;
        const li = document.createElement('li'); appendInline(li, item[1]); list.append(li); index++;
      }
      root.append(list); continue;
    }
    const paragraph = [];
    while (index < lines.length && lines[index].trim() && !/^```|^(#{1,6})\s+|^>\s?|^(?:[-*+]\s+|\d+\.\s+)/.test(lines[index])) paragraph.push(lines[index++]);
    appendParagraph(paragraph);
  }
}

function appendInline(parent, value) {
  const pattern = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\(https?:\/\/[^\s)]+\))/g;
  let cursor = 0;
  for (const match of String(value).matchAll(pattern)) {
    if (match.index > cursor) parent.append(document.createTextNode(value.slice(cursor, match.index)));
    const token = match[0];
    if (token.startsWith('**')) {
      const strong = document.createElement('strong'); strong.textContent = token.slice(2, -2); parent.append(strong);
    } else if (token.startsWith('`')) {
      const code = document.createElement('code'); code.textContent = token.slice(1, -1); parent.append(code);
    } else {
      const [, label, url] = token.match(/^\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)$/) || [];
      const link = document.createElement('a'); link.textContent = label; link.href = url; link.target = '_blank'; link.rel = 'noreferrer'; parent.append(link);
    }
    cursor = match.index + token.length;
  }
  if (cursor < value.length) parent.append(document.createTextNode(value.slice(cursor)));
}

function mergeReasoningParts(cursor, container, parts, replace = false) {
  if (replace) cursor.nativeParts = new Map();
  for (const part of parts || []) {
    if (part && part.id && (
      (part.kind === 'tool' && typeof part.tool === 'string') ||
      (part.kind !== 'tool' && typeof part.text === 'string')
    )) cursor.nativeParts.set(part.id, part);
  }
  const bounded = Array.from(cursor.nativeParts.values()).slice(-MAX_STREAM_LINES);
  cursor.nativeParts = new Map(bounded.map((part) => [part.id, part]));
  renderNativeReasoning(container, bounded);
}

function escapeHtml(value) {
  const div = document.createElement('div');
  div.textContent = String(value ?? '');
  return div.innerHTML;
}

function renderStatus(data) {
  const now = new Date().toLocaleTimeString();
  document.getElementById('updated-at').textContent = 'updated ' + now;

  const brain = data.brain || {};
  const statusNode = document.getElementById('brain-status');
  const stateText = brain.state || 'unknown';
  document.getElementById('brain-panel').classList.toggle('is-working', /WORKING|INVOKING/i.test(stateText));
  statusNode.textContent = stateText;
  statusNode.className = 'brain-status ' + (
    /WORKING/i.test(stateText) ? 'working' : (/CLAIM|ERROR|STOPPED/i.test(stateText) ? 'claiming' : '')
  );
  const checkpoint = document.getElementById('brain-checkpoint');
  checkpoint.textContent = brain.checkpoint ? 'checkpoint: ' + brain.checkpoint.split('\n')[0] : 'checkpoint: —';
  const usage = brain.usage;
  document.getElementById('brain-usage').textContent = usage
    ? `${usage.remainingPercent}% left · reserve ${usage.reservePercent}% · safe ${usage.safePacePerDay}%/day · ${usage.freshness.toLowerCase()} ${usage.ageMinutes}m · ${usage.runsToday} runs`
    : 'usage: —';
  document.getElementById('brain-last-decision').textContent = brain.lastDecision
    ? minuteTime(brain.lastDecision.at) : '—';
  document.getElementById('brain-wave').textContent = brain.wave ? `${brain.wave[0]} · ${brain.wave[1]}` : '';
  const action = document.getElementById('desktop-action');
  const actionText = document.getElementById('desktop-action-text');
  const requested = brain.desktopAction || '';
  const needsDesktop = /^PING DESKTOP MANAGER NOW\b/i.test(requested);
  action.classList.toggle('hidden', !needsDesktop);
  actionText.textContent = needsDesktop ? requested.replace(/^PING DESKTOP MANAGER NOW\s*[—-]?\s*/i, '') || 'Action requested' : '';

  for (const key of members) {
    const member = data.members?.[key] || {};
    const card = document.getElementById('member-' + key);
    const header = document.querySelector('#member-' + key + ' header');
    const memberState = member.state || 'STANDBY';
    // Only a real process-backed WORKING state gets the full green card.
    // REPORT READY intentionally retains its normal visual treatment.
    card.classList.toggle('is-working', /^WORKING\b/i.test(memberState));
    header.querySelector('.member-state').textContent = memberState + (member.lane ? ' · ' + member.lane : '');
    header.querySelector('.member-state').className = 'member-state ' + (
      /ATTENTION|STALLED/.test(memberState) ? 'attention' : (/WORKING|REPORT READY/.test(memberState) ? 'working' : 'standby')
    );
    const report = member.report;
    header.querySelector('.report').innerHTML = report
      ? 'report: <span class="title">' + escapeHtml(report.title) + '</span> · ' + escapeHtml(report.file) + (report.pending ? ' · pending' : '')
      : 'report: —';
    const mailbox = member.mailbox;
    header.querySelector('.mailbox').textContent = mailbox
      ? 'ping [' + mailbox.kind + ']: ' + (mailbox.message || '')
      : '';
    const lastWrite = member.log?.mtime;
    header.querySelector('.last-write').textContent = lastWrite
      ? minuteTime(lastWrite)
      : '—';
  }
}

async function pollStatus() {
  try {
    const response = await fetch('/api/status');
    if (!response.ok) return;
    const data = await response.json();
    renderStatus(data);
  } catch { /* transient */ }
}

async function pollMember(key) {
  const cursor = state[key];
  try {
    const url = `/api/stream?member=${key}&after=${cursor.after}&native=1`;
    const response = await fetch(url);
    if (!response.ok) return;
    const data = await response.json();
    const stream = document.getElementById('stream-' + key);
    if (data.mode === 'native-reasoning') {
      cursor.file = data.file || 'OpenCode native reasoning';
      mergeReasoningParts(cursor, stream, data.parts, true);
      return;
    }
    if (cursor.file && data.file && cursor.file !== data.file) {
      cursor.file = data.file;
      cursor.after = 0;
      cursor.lines = [];
      cursor.nativeParts = new Map();
      stream.textContent = '[loading current run]';
      return;
    }
    cursor.file = data.file || cursor.file;
    cursor.after = data.next;
    if (data.lines && data.lines.length) appendLines(stream, data.lines);
  } catch { /* transient */ }
}

async function pollBrain() {
  if (!state.brain) state.brain = { after: 0, nativeParts: new Map() };
  try {
    const url = `/api/brain-stream?after=${state.brain.after}`;
    const response = await fetch(url);
    if (!response.ok) return;
    const data = await response.json();
    const cursor = state.brain;
    const stream = document.getElementById('brain-stream');
    if (data.file && stream.dataset.file !== data.file) {
      stream.dataset.file = data.file;
      cursor.after = 0;
      cursor.nativeParts = new Map();
      stream.textContent = '[loading current BRAIN run]';
      return;
    }
    cursor.after = data.next;
    if (data.mode === 'native-reasoning') {
      mergeReasoningParts(cursor, stream, data.parts);
      return;
    }
    if (data.lines && data.lines.length) appendLines(stream, data.lines);
  } catch { /* transient */ }
}

initColumns();
document.getElementById('brain-stream').addEventListener('scroll', (event) => {
  const stream = event.currentTarget;
  setFollowState(stream, isAtEnd(stream));
}, { passive: true });
document.addEventListener('click', (event) => {
  const button = event.target.closest('.jump-end');
  if (!button) return;
  const stream = document.getElementById(button.dataset.for);
  if (!stream) return;
  setFollowState(stream, true);
  stream.scrollTo({ top: stream.scrollHeight, behavior: 'smooth' });
});
pollStatus();
pollBrain();
for (const key of members) pollMember(key);
setInterval(pollStatus, STATUS_MS);
setInterval(pollBrain, STREAM_MS);
setInterval(() => { for (const key of members) pollMember(key); }, STREAM_MS);
