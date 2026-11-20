(function () {
  const STATUS = {
    inbox: "Inbox", backlog: "Backlog", next: "Next", doing: "Doing", waiting: "Blocked", done: "Done", dropped: "Dropped"
  };
  const BOARD = ["backlog", "next", "doing", "waiting"];
  const UNBLOCK_TO = ["next", "doing", "done", "backlog", "dropped"];
  const PCOLORS = ["#2d5bdb", "#0f8a6a", "#c26a12", "#9b3fc1", "#c0352b", "#1d8fb3", "#7a6a12", "#d0458a"];
  const S = {
    db: null, items: new Map(), steps: new Map(), kind: "item", projects: new Map(), gotItems: false, gotProjects: false, offline: false, readOnly: false,
    view: "inbox", col: "doing", proj: "all", q: "", open: null, npOpen: false, guide: null, guideOpen: false
  };
  S.expanded = new Set(); S.journal = new Map();
  try { const x = JSON.parse(localStorage.getItem("wl.expanded") || "[]"); if (Array.isArray(x)) S.expanded = new Set(x); } catch (e) {}
  const saveExpanded = () => { try { localStorage.setItem("wl.expanded", JSON.stringify([...S.expanded])); } catch (e) {} };
  try { const v = localStorage.getItem("wl.view"); if (v && ["inbox", "board", "done", "history"].includes(v)) S.view = v; const c = localStorage.getItem("wl.col"); if (c && BOARD.includes(c)) S.col = c; } catch (e) {}
  // History: the log of changes to these fields, kept 90 days, and what the History tab has shown you.
  const LOGGED = ["status", "blockedBy", "project", "priority", "due"], KEEP = 90 * 864e5, HIST_PAGE = 60;
  const SRC = { cli: "Claude Code", phone: "Claude app", page: "you" };
  Object.assign(S, { history: new Map(), hist: [], histTasks: new Set(), who: "all", histN: HIST_PAGE, seen: "" });
  try { S.seen = localStorage.getItem("wl.histSeen") || ""; } catch (e) {}
  if (!S.seen) S.seen = new Date().toISOString();
  S.histPrev = S.seen;

  const $ = (s, r = document) => r.querySelector(s);
  const now = () => new Date().toISOString();
  const newId = (p = "i") => p + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const today = () => new Date().toISOString().slice(0, 10);

  // ---------- writes: one at a time per document ----------
  const Q = new Map();
  const entry = p => { let e = Q.get(p); if (!e) { e = { path: p, pending: null, busy: false }; Q.set(p, e); } return e; };
  function enqueue(path, data) { const e = entry(path); e.pending = Object.assign(e.pending || {}, data); pump(e); }
  async function pump(e) {
    if (e.busy || !e.pending || !S.db) return;
    e.busy = true; const d = e.pending; e.pending = null;
    try { await S.db.doc(e.path).update(d); }
    catch (err) {
      if (err && err.code === "unavailable") { await new Promise(r => setTimeout(r, 400 + Math.random() * 600)); try { await S.db.doc(e.path).update(d); } catch (e2) { writeErr(e2); } }
      else writeErr(err);
    }
    e.busy = false; if (e.pending) pump(e);
  }
  async function create(path, obj) {
    const e = entry(path); e.busy = true;
    try { await S.db.doc(path).set(obj); } catch (err) { writeErr(err); }
    e.busy = false; pump(e);
  }
  function writeErr(err) {
    const c = err && err.code;
    if (c === "invalid_argument") { S.readOnly = true; toast("This worklog is read-only for you."); render(); }
    else if (c === "quota_exceeded") toast("Storage is full. Delete some old done items to make room.");
    else if (c === "resource_exhausted") toast("Too many changes at once. Give it a second and try again.");
    else toast("Couldn't save that change. Check your connection and try again.");
  }

  // A value as the history log compares it: no priority is 0, any other missing value "".
  const norm = (k, v) => k === "priority" ? (v || 0) : v == null ? "" : v;
  function patch(id, data) {
    const it = S.items.get(id); if (!it || S.readOnly) return;
    const t = now(), full = Object.assign({}, data, { updated: t, by: "page" });
    const ch = {};
    for (const k of LOGGED) if (k in data && norm(k, data[k]) !== norm(k, it[k])) ch[k] = [norm(k, it[k]), norm(k, data[k])];
    S.items.set(id, Object.assign({}, it, full));
    enqueue("items/" + id, full);
    if (Object.keys(ch).length) logChange(id, t, ch);
    render();
  }
  // One history entry per change, at the task's new `updated`. A burst on one task from this page
  // (a blocker saved as you type, a quick change of mind) stays one entry: from where it started to
  // where it ended. A field that ends where it started stays in the entry and shows nothing.
  let lastLog = null;
  function logChange(task, at, ch) {
    const prev = lastLog && lastLog.task === task && Date.now() - lastLog.t < 120000 && S.history.get(lastLog.id);
    if (prev) {
      const changes = Object.assign({}, prev.changes);
      for (const [k, v] of Object.entries(ch)) changes[k] = [changes[k] ? changes[k][0] : v[0], v[1]];
      S.history.set(prev.id, Object.assign({}, prev, { at, changes }));
      enqueue("history/" + prev.id, { at, changes });
    } else {
      const id = task + "-" + at.replace(/\D/g, ""), obj = { task, at, by: "page", changes: ch };
      S.history.set(id, Object.assign({ id }, obj));
      create("history/" + id, obj);
      lastLog = { task, id };
    }
    lastLog.t = Date.now();
  }
  function patchStep(id, data) {
    const st = S.steps.get(id); if (!st || S.readOnly) return;
    const full = Object.assign({}, data, { updated: now(), by: "page" });
    S.steps.set(id, Object.assign({}, st, full));
    enqueue("steps/" + id, full);
    render();
  }
  const setStepDone = (id, done) => patchStep(id, { done, doneAt: done ? now() : "" });
  // A pane's document: a task or a step.
  const cur = P => (P.kind === "step" ? S.steps : S.items).get(P.id);
  const patchCur = (P, data) => (P.kind === "step" ? patchStep : patch)(P.id, data);
  function setStatus(id, status) {
    const it = S.items.get(id); if (!it) return;
    const d = { status };
    if (status === "done" || status === "dropped") d.doneAt = it.doneAt || now(); else d.doneAt = "";
    if (status !== it.status) d.rank = null;
    // Leaving Blocked, or leaving Doing while it waits on you, means the blocker is gone.
    if (it.blockedBy && ["waiting", "doing"].includes(it.status) && status !== it.status && status !== "waiting") d.blockedBy = "";
    patch(id, d);
  }
  // A blocker on a task moves it to Blocked, and clearing it moves it back to Next. A task in Doing
  // that already has one waits on you, and agents put it there: changing its blocker leaves it in Doing.
  // A step only shows its blocker.
  function setBlocked(P, v) {
    if (P.kind === "step") { patchStep(P.id, { blockedBy: v }); return; }
    const it = S.items.get(P.id); if (!it) return;
    const d = { blockedBy: v };
    if (v && !it.blockedBy && ["inbox", "backlog", "next", "doing"].includes(it.status)) d.status = "waiting";
    if (!v && it.status === "waiting") d.status = "next";
    if (d.status) d.rank = null;
    patch(P.id, d);
  }
  // Unblocking clears the blocker and moves the task where the user chooses. A reason, if given, goes to the journal.
  function unblock(P) {
    const it = cur(P); if (!it || !P.ub || S.readOnly) return;
    const to = P.ub.to, why = oneLine(f(P, "#fUbWhy").value), was = it.blockedBy || "";
    P.ub = null; dirty[P.name + "#fBlocked"] = false; clearTimeout(timers[P.name + "#fBlocked"]);
    const d = { status: to, blockedBy: "", doneAt: to === "done" || to === "dropped" ? it.doneAt || now() : "" };
    if (to !== it.status) d.rank = null;
    patch(P.id, d);
    const jid = why ? addNote(P.id, `Unblocked to ${STATUS[to]}: ${why}${was ? ` (was: ${was})` : ""}`) : null;
    toast(`Unblocked. Moved to ${STATUS[to]}.`, () => {
      patch(it.id, { status: it.status, blockedBy: was, doneAt: it.doneAt || "", rank: ranked(it) ? it.rank : null });
      if (jid) { S.journal.delete(jid); S.db.doc("journal/" + jid).delete().catch(writeErr); render(); }
    });
  }
  function addNote(task, text) {
    const t = now(), id = task + "-" + t.replace(/\D/g, "").slice(0, 14);
    const obj = { task, at: t, by: "page", kind: "note", text };
    S.journal.set(id, Object.assign({ id }, obj));
    create("journal/" + id, obj);
    render();
    return id;
  }
  function addItem(fields) {
    if (!S.db || S.readOnly) return null;
    const id = newId(), t = now();
    const obj = Object.assign({ title: "", notes: "", status: "inbox", project: "", priority: 0, due: "", links: [], blockedBy: "", created: t, updated: t, doneAt: "", source: "page", by: "page" }, fields);
    S.items.set(id, Object.assign({ id }, obj));
    create("items/" + id, obj);
    render();
    return id;
  }
  function addStep(task, fields) {
    if (!S.db || S.readOnly) return null;
    const id = newId("s"), t = now();
    const order = Math.max(0, ...children(task).map(k => k.order || 0)) + 1;
    const obj = Object.assign({ task, title: "", done: false, doneAt: "", blockedBy: "", notes: "", links: [], order, created: t, updated: t, by: "page" }, fields);
    S.steps.set(id, Object.assign({ id }, obj));
    create("steps/" + id, obj);
    render();
    return id;
  }
  // Deleting a task deletes its steps with it.
  function deleteItem(id) {
    for (const k of children(id)) { S.steps.delete(k.id); S.db.doc("steps/" + k.id).delete().catch(writeErr); }
    for (const j of journalOf(id)) { S.journal.delete(j.id); S.db.doc("journal/" + j.id).delete().catch(writeErr); }
    for (const h of [...S.history.values()].filter(h => h.task === id)) { S.history.delete(h.id); S.db.doc("history/" + h.id).delete().catch(writeErr); }
    S.items.delete(id);
    S.db.doc("items/" + id).delete().catch(writeErr);
    closeSheet(); render(); toast("Deleted.");
  }
  function deleteStep(id) {
    const task = S.steps.get(id) && S.steps.get(id).task;
    S.steps.delete(id);
    S.db.doc("steps/" + id).delete().catch(writeErr);
    if (PS.id === id) closeSide(); else if (task && S.items.has(task)) openSheet(task); else closeSheet();
    render(); toast("Step deleted.");
  }
  // A step that grew into real work becomes a task of its own, in its task's project.
  function detachStep(id) {
    const st = S.steps.get(id); if (!st) return;
    const task = S.items.get(st.task) || {};
    const nid = addItem({ title: st.title, notes: st.notes || "", links: st.links || [], blockedBy: st.blockedBy || "", status: st.done ? "done" : st.blockedBy ? "waiting" : "next", doneAt: st.doneAt || "", project: task.project || "" });
    if (!nid) return;
    S.steps.delete(id);
    S.db.doc("steps/" + id).delete().catch(writeErr);
    openSheet(nid); toast("Now a separate task.");
  }

  // ---------- derived ----------
  const children = id => [...S.steps.values()].filter(k => k.task === id).sort((a, b) => (a.order || 0) - (b.order || 0) || (a.created || "").localeCompare(b.created || ""));
  const isOpen = i => i.status !== "done" && i.status !== "dropped";
  const journalOf = id => [...S.journal.values()].filter(j => j.task === id).sort((a, b) => (b.at || "").localeCompare(a.at || ""));
  const stepOpen = k => !k.done;
  const tasks = () => [...S.items.values()];
  // A link is a URL, or {url, title} once it has a description.
  const lurl = l => typeof l === "string" ? l : (l && l.url) || "";
  const ltitle = l => typeof l === "string" ? "" : (l && l.title) || "";
  const text = i => ((i.title || "") + " " + (i.notes || "") + " " + (i.blockedBy || "") + " " + (i.links || []).map(l => lurl(l) + " " + ltitle(l)).join(" ")).toLowerCase();
  // A task matches the search when it or one of its steps does.
  function found(i) {
    if (!S.q) return true;
    const h = [i, ...children(i.id)].map(text).join(" ");
    return S.q.split(/\s+/).every(w => h.includes(w));
  }
  function matches(i) {
    if (S.proj !== "all" && (i.project || "") !== (S.proj === "none" ? "" : S.proj)) return false;
    return found(i);
  }
  // The tasks each tab lists. The project chips count the same.
  const IN_VIEW = { inbox: i => i.status === "inbox", board: i => BOARD.includes(i.status), done: i => !isOpen(i), history: i => S.histTasks.has(i.id) };
  // How close a due date is, in local calendar days. Overdue, today and tomorrow stand out on the card.
  const localDay = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  function dueInfo(i) {
    if (!i.due || !isOpen(i)) return null;
    const n = Math.round((new Date(i.due + "T12:00:00") - new Date(localDay() + "T12:00:00")) / 864e5);
    if (isNaN(n)) return null;
    if (n < 0) return { level: "over", label: n === -1 ? "Due yesterday" : `${-n} days overdue` };
    if (n === 0) return { level: "today", label: "Due today" };
    if (n === 1) return { level: "soon", label: "Due tomorrow" };
    if (n < 7) return { level: "week", label: "Due " + new Date(i.due + "T12:00:00").toLocaleDateString(undefined, { weekday: "short" }) };
    return { level: "later", label: "Due " + fmtDay(i.due) };
  }
  const prio = i => i.priority ? i.priority : 9;
  const byWork = (a, b) => prio(a) - prio(b) || (a.due || "9999").localeCompare(b.due || "9999") || (b.updated || "").localeCompare(a.updated || "");
  // Board order: cards without a rank (new to the column) first by priority, then the hand-ordered ones.
  const ranked = i => typeof i.rank === "number";
  const byBoard = (a, b) => ranked(a) !== ranked(b) ? (ranked(a) ? 1 : -1) : ranked(a) ? a.rank - b.rank || byWork(a, b) : byWork(a, b);
  // The projects a task can be given: the active ones, and its own even when archived.
  function projOptions(cur) {
    const projs = [...S.projects.values()].filter(p => p.status !== "archived" || p.id === cur).sort((a, b) => (a.name || "").localeCompare(b.name || ""));
    return `<option value="">None</option>` + projs.map(p => `<option value="${esc(p.id)}"${p.id === cur ? " selected" : ""}>${esc(p.name)}</option>`).join("");
  }

  // ---------- render ----------
  const picking = () => { const a = document.activeElement; return !!(a && a.dataset && a.dataset.setproj); };
  function render() {
    document.querySelectorAll(".tab").forEach(t => t.setAttribute("aria-selected", String(t.dataset.view === S.view)));
    const all = tasks();
    const nIn = all.filter(i => i.status === "inbox").length;
    const nIb = $("#nInbox"); nIb.textContent = nIn; nIb.classList.toggle("hot", nIn > 0);
    $("#nBoard").textContent = all.filter(i => i.status === "doing").length;
    // History marks Claude's changes since you last had the tab open as New.
    S.hist = historyEvents(); S.histTasks = new Set(S.hist.map(e => e.task));
    if (S.view === "history") { S.seen = now(); try { localStorage.setItem("wl.histSeen", S.seen); } catch (e) {} }
    const capReady = !!S.db && !S.readOnly;
    $("#cap").disabled = !capReady; $("#capBtn").disabled = !capReady || !$("#cap").value.trim();
    // A live update mid-drag would replace the card or row being dragged; the drop renders instead.
    // So would one while a card's project list is open; it renders when the list closes.
    renderChips(); if (!(D && D.active) && !picking()) renderMain();
    if (R && R.active) return;
    if (PM.id) refreshSheet(PM); if (PS.id) refreshSheet(PS);
  }

  function renderChips() {
    const el = $("#chips");
    // A chip counts its project's tasks in the current tab that match the search.
    const shown = tasks().filter(i => IN_VIEW[S.view](i) && found(i));
    const byName = (a, b) => (a.name || "").localeCompare(b.name || "");
    const projs = [...S.projects.values()].filter(p => p.status !== "archived").sort(byName);
    // An archived project's chip shows on Done, where its tasks are, and while it is the filter.
    const arch = [...S.projects.values()].filter(p => p.status === "archived" && (S.view === "done" || S.proj === p.id)).sort(byName);
    const chip = p => {
      const n = shown.filter(i => i.project === p.id).length, ed = S.proj === p.id && S.db && !S.readOnly, a = p.status === "archived";
      return `<button class="chip${a ? " arch" : ""}" data-proj="${esc(p.id)}" aria-pressed="${S.proj === p.id}"${ed ? ` title="Edit project" aria-haspopup="dialog"` : a ? ` title="Archived"` : ""}><i style="background:${esc(p.color)}"></i>${esc(p.name)} <span class="n">${n}</span>${ed ? `<span class="ed" aria-hidden="true">\u25BE</span>` : ""}</button>`;
    };
    let h = `<button class="chip" data-proj="all" aria-pressed="${S.proj === "all"}">All</button>`;
    h += projs.map(chip).join("");
    if (projs.length || arch.length) h += `<button class="chip" data-proj="none" aria-pressed="${S.proj === "none"}">No project</button>`;
    if (S.db && !S.readOnly) h += `<button class="chip add" data-addproj aria-haspopup="dialog" aria-expanded="${S.npOpen && !S.npEdit}">+ Project</button>`;
    // Archived chips come last, so the ones Done adds move nothing that the other tabs show.
    h += arch.map(chip).join("");
    el.innerHTML = h;
  }

  // A project's name and color, in a popover under its chip. Opened from "+ Project" it creates one,
  // with the next color in turn; opened from the selected project's chip it edits that one, and
  // archives or restores it, or deletes it while no task uses it.
  function openProject(btn, id) {
    const p = id && S.projects.get(id);
    S.npOpen = true; S.npEdit = p ? id : null; S.npColor = p ? p.color : PCOLORS[S.projects.size % PCOLORS.length];
    const np = $("#np");
    const left = !p ? "" : p.status === "archived" ? `<button type="button" class="btn2 np-l" id="npRestore">Restore</button>`
      : tasks().some(i => i.project === p.id) ? `<button type="button" class="btn2 np-l" id="npArch" title="Takes it off the filters; its tasks keep it">Archive</button>`
      : `<button type="button" class="del" id="npDel">Delete</button>`;
    np.innerHTML = `<input class="inp" id="npName" placeholder="Project name" maxlength="40" aria-label="Project name" value="${p ? esc(p.name) : ""}">
      <div class="sw" role="radiogroup" aria-label="Color">${PCOLORS.map((c, k) => `<button type="button" role="radio" data-color="${c}" style="--c:${c}" aria-checked="${c === S.npColor}" aria-label="Color ${k + 1}"></button>`).join("")}</div>
      <label class="np-opt"><input type="checkbox" id="npStacked"${p && p.stacked ? " checked" : ""}><span>Stack its tasks on the board<small>For bulk work. Blocked, P1 and due-soon tasks still show on their own.</small></span></label>
      <div class="np-act">${left}<button type="button" class="btn2" data-npcancel>Cancel</button><button type="button" class="btn2 go" id="npGo"${p ? "" : " disabled"}>${p ? "Save" : "Create"}</button></div>`;
    np.hidden = false; btn.setAttribute("aria-expanded", "true");
    const r = btn.getBoundingClientRect();
    np.style.top = (r.bottom + 6) + "px";
    np.style.left = Math.max(16, Math.min(r.left, window.innerWidth - np.offsetWidth - 16)) + "px";
    const inp = $("#npName"); inp.focus(); inp.select();
  }
  function closeProject() {
    if (!S.npOpen) return;
    S.npOpen = false; S.npEdit = null; $("#np").hidden = true; $("#np").innerHTML = "";
    document.querySelectorAll("#chips [aria-expanded]").forEach(b => b.setAttribute("aria-expanded", "false"));
  }
  function saveProject() {
    const name = $("#npName").value.trim(); if (!name || !S.db || S.readOnly) return;
    const p = S.npEdit && S.projects.get(S.npEdit), stacked = $("#npStacked").checked;
    if (p) {
      const d = { name, color: S.npColor, stacked };
      S.projects.set(p.id, Object.assign({}, p, d)); enqueue("projects/" + p.id, d);
    } else {
      const id = "p" + name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 30) + "-" + Math.random().toString(36).slice(2, 5);
      const obj = { name, color: S.npColor, status: "active", stacked, created: now(), description: "" };
      S.projects.set(id, Object.assign({ id }, obj)); create("projects/" + id, obj); S.proj = id;
    }
    closeProject(); render();
  }
  // Archiving keeps a project, so its tasks, done ones included, keep their project; only the filters
  // leave it out (renderChips).
  function setProjectStatus(id, status) {
    const p = S.projects.get(id); if (!p || !S.db || S.readOnly) return;
    const was = p.status || "active";
    S.projects.set(id, Object.assign({}, p, { status })); enqueue("projects/" + id, { status });
    if (status === "archived" && S.proj === id && S.view !== "done") S.proj = "all";
    closeProject(); render();
    toast(status === "archived" ? "Project archived. Its chip shows under Done." : "Project restored.", () => setProjectStatus(id, was));
  }
  // Only a project no task uses is offered for deletion. A task given it meanwhile moves to No project,
  // so no task points at a project that is gone.
  function deleteProject(id) {
    if (!S.projects.has(id) || S.readOnly) return;
    for (const i of tasks().filter(i => i.project === id)) patch(i.id, { project: "" });
    S.projects.delete(id); S.db.doc("projects/" + id).delete().catch(writeErr);
    if (S.proj === id) S.proj = "all";
    closeProject(); render(); toast("Project deleted.");
  }

  function card(i, o = {}) {
    const p = S.projects.get(i.project), kids = children(i.id);
    const dn = kids.filter(k => k.done).length;
    let meta = "";
    const nested = o.steps && kids.length, expanded = nested && S.expanded.has(i.id);
    const prog = kids.length ? `<span class="bar" aria-hidden="true"><i style="width:${Math.round(dn / kids.length * 100)}%"></i></span>${dn}/${kids.length} steps` : "";
    if (nested) meta += `<button class="stoggle" data-toggle="${esc(i.id)}" aria-expanded="${expanded}">${prog}</button>`;
    else if (kids.length) meta += `<span class="prog">${prog}</span>`;
    const nb = kids.filter(k => stepOpen(k) && k.blockedBy).length;
    if (nb) meta += `<span class="blkn">${nb} blocked</span>`;
    if (i.handoff && isOpen(i)) meta += `<span>Handoff ${ago(i.handoffAt || i.updated)}</span>`;
    if (o.done) meta += `<span>${fmtDay((i.doneAt || i.updated || "").slice(0, 10))}</span>`;
    // Triage sets the project on the card too. The native select lies over the pill's face, so the
    // whole pill opens it; the face shows the project, so the eyebrow leaves it out.
    const triage = o.triage && !S.readOnly;
    const move = s => `<button data-move="${s}">${s === "dropped" ? "Drop" : STATUS[s]}</button>`;
    const tri = triage ? `<div class="triage">${["backlog", "next", "doing"].map(move).join("")}<label class="tproj${p ? " has" : ""}"><i style="background:${p ? esc(p.color) : "transparent"}"></i><span>${p ? esc(p.name) : "Project"}</span><select data-setproj="${esc(i.id)}" aria-label="Project">${projOptions(i.project)}</select></label>${move("dropped")}</div>` : "";
    // Project is the card's only hue; hidden when the filter already names it.
    const showProj = p && S.proj !== p.id && !triage;
    const du = dueInfo(i), urgent = du && ["over", "today", "soon"].includes(du.level);
    const bar = urgent ? `<div class="dbar"><span>${esc(du.label)}</span><span>${esc(new Date(i.due + "T12:00:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }))}</span></div>` : "";
    const right = (du && !urgent ? `<span class="dp ${du.level}">${esc(du.label)}</span>` : "") + (i.priority ? `<span class="pri p${i.priority}" title="Priority ${i.priority}">P${i.priority}</span>` : "");
    const eb = showProj || right ? `<div class="eb">${showProj ? `<span class="proj"><i style="background:${esc(p.color)}"></i>${esc(p.name)}</span>` : ""}${right ? `<span class="eb-r">${right}</span>` : ""}</div>` : "";
    return `<article class="card${o.done ? " done-card" : ""}${urgent ? " due-" + du.level : ""}" data-id="${esc(i.id)}" data-s="${esc(i.status)}">
      ${bar}${eb}<div class="t">${esc(i.title || "Untitled")}</div>
      ${i.blockedBy && isOpen(i) ? `<div class="blk">${esc(i.blockedBy)}</div>` : ""}
      ${o.note && i.notes ? `<div class="note">${esc(i.notes)}</div>` : ""}
      <div class="meta">${meta}</div>${expanded ? stepList(kids) : ""}${tri}</article>`;
  }

  // While the board shows everything, a stacked project's tasks in a column collapse into one card,
  // except the ones that need the user: blocked, P1 or due within a day. A stack of one is just its card.
  const standsOut = i => !!i.blockedBy || i.priority === 1 || ["over", "today", "soon"].includes((dueInfo(i) || {}).level);
  function stackUp(col) {
    if (S.proj !== "all" || S.q) return { loose: col, stacks: [] };
    const groups = new Map();
    for (const i of col) { const p = S.projects.get(i.project); if (p && p.stacked && !standsOut(i)) groups.set(p.id, [...(groups.get(p.id) || []), i]); }
    const stacks = [...groups].filter(([, its]) => its.length > 1).map(([id, its]) => ({ p: S.projects.get(id), its }));
    const hidden = new Set(stacks.flatMap(x => x.its.map(i => i.id)));
    return { loose: col.filter(i => !hidden.has(i.id)), stacks };
  }
  function stackCard({ p, its }) {
    const all = tasks().filter(i => i.project === p.id && i.status !== "dropped"), dn = all.filter(i => i.status === "done").length;
    const peek = its.slice(0, 2).map(i => i.title || "Untitled").join(" · ") + (its.length > 2 ? " …" : "");
    return `<article class="card stack" data-stack="${esc(p.id)}" title="Show all of ${esc(p.name)}">
      <div class="eb"><span class="proj"><i style="background:${esc(p.color)}"></i>${esc(p.name)}</span></div>
      <div class="t">${its.length} tasks</div><div class="note">${esc(peek)}</div>
      <div class="meta"><span class="prog"><span class="bar" aria-hidden="true"><i style="width:${Math.round(dn / all.length * 100)}%"></i></span>${dn}/${all.length} done</span></div></article>`;
  }

  function stepList(kids) {
    const ordered = [...kids.filter(stepOpen), ...kids.filter(k => k.done)];
    return `<div class="steps">${ordered.map(k => {
      const d = !!k.done;
      const why = !d && k.blockedBy ? `<span class="why b">Blocked: ${esc(k.blockedBy)}</span>` : "";
      return `<div class="step${d ? " d" : ""}"><input type="checkbox" data-check="${esc(k.id)}"${d ? " checked" : ""}${S.readOnly ? " disabled" : ""} aria-label="Done: ${esc(k.title || "Untitled")}"><span class="stt" data-ostep="${esc(k.id)}">${esc(k.title || "Untitled")}${why}</span></div>`;
    }).join("")}</div>`;
  }

  function renderMain() {
    const m = $("#main");
    if (S.offline) { m.innerHTML = `<div class="narrow"><div class="empty"><strong>Open this page in Claude to load your worklog</strong>The tracker's data lives with the artifact, so it only loads inside the Claude app or claude.ai.</div></div>`; return; }
    if (!S.gotItems) { m.innerHTML = `<p class="status-msg">Loading your worklog…</p>`; return; }
    const items = tasks().filter(matches);
    if (S.view === "inbox") {
      const inbox = items.filter(IN_VIEW.inbox).sort((a, b) => (b.created || "").localeCompare(a.created || ""));
      m.innerHTML = `<div class="narrow">${inbox.length ? `<div class="list">${inbox.map(i => card(i, { triage: true, note: true })).join("")}</div>`
        : `<div class="empty"><strong>Inbox is clear</strong>${S.q || S.proj !== "all" ? "Nothing matches this filter." : "Anything you capture below, or send to Claude from your phone, lands here until you sort it."}</div>`}</div>`;
    } else if (S.view === "history") {
      m.innerHTML = renderHistory(new Set(items.map(i => i.id)));
    } else if (S.view === "board") {
      const onBoard = items.filter(IN_VIEW.board);
      let h = `<div class="seg" role="group" aria-label="Column">${BOARD.map(s => `<button data-col="${s}" aria-pressed="${S.col === s}">${STATUS[s]} <span class="ct">${onBoard.filter(i => i.status === s).length}</span></button>`).join("")}</div><div class="board">`;
      for (const s of BOARD) {
        const col = onBoard.filter(i => i.status === s).sort(byBoard), { loose, stacks } = stackUp(col);
        h += `<section class="col${S.col === s ? " active" : ""}" data-s="${s}"><div class="col-h">${STATUS[s]}<span class="ct">${col.length}</span></div>
          <div class="list">${col.length ? loose.map(i => card(i, { steps: true })).join("") + stacks.map(stackCard).join("") : `<div class="col-empty">Nothing here.</div>`}</div></section>`;
      }
      m.innerHTML = h + `</div>`;
    } else {
      const done = items.filter(IN_VIEW.done).sort((a, b) => (b.doneAt || b.updated || "").localeCompare(a.doneAt || a.updated || "")).slice(0, 150);
      m.innerHTML = `<div class="narrow">${done.length ? `<div class="list">${done.map(i => card(i, { done: true })).join("")}</div>` : `<div class="empty"><strong>Nothing finished yet</strong>Done and dropped items collect here.</div>`}</div>`;
    }
  }

  // ---------- history ----------
  // Every event of the last 90 days, newest first: the history log's changes, and what tasks, steps and
  // the journal record themselves (created, done or dropped, steps added and ticked, handoffs, sessions
  // and notes). A task's last write that nothing else explains shows as "Edited". `by` is "" when unknown.
  // `text` is HTML for changes and plain text for steps and journal lines, formatted only for the rows shown.
  function historyEvents() {
    const since = new Date(Date.now() - KEEP).toISOString(), ev = [], when = new Map(), moved = new Set();
    const near = (a, b) => !!a && !!b && Math.abs(Date.parse(a) - Date.parse(b)) < 5000;
    const add = (task, at, by, kind, text) => {
      if (typeof at !== "string" || at < since || !S.items.has(task)) return;
      ev.push({ task, at, by: by || "", kind, text });
      (when.get(task) || when.set(task, []).get(task)).push(Date.parse(at));
    };
    for (const h of S.history.values()) {
      if (!h.changes || typeof h.changes !== "object") continue;
      // An entry that shows nothing still explains its task's `updated`.
      add(h.task, h.at, h.by, "change", changeText(h.changes));
      if (Array.isArray(h.changes.status)) moved.add(h.task + ":" + h.changes.status[1]);
    }
    for (const i of S.items.values()) {
      add(i.id, i.created, i.source || (near(i.created, i.updated) ? i.by : ""), "created", "Created");
      if (!isOpen(i) && !moved.has(i.id + ":" + i.status)) add(i.id, i.doneAt, near(i.doneAt, i.updated) ? i.by : "", "status", STATUS[i.status]);
      if (i.handoffAt) add(i.id, i.handoffAt, i.handoffBy, "handoff", "Wrote a handoff");
    }
    // In checklist order, so steps created together keep it.
    for (const k of [...S.steps.values()].sort((a, b) => (a.order || 0) - (b.order || 0))) {
      add(k.task, k.created, near(k.created, k.updated) ? k.by : "", "step", k.title || "Untitled");
      if (k.done) add(k.task, k.doneAt, near(k.doneAt, k.updated) ? k.by : "", "tick", k.title || "Untitled");
    }
    for (const j of S.journal.values()) add(j.task, j.at, j.by, j.kind === "session" ? "session" : "note", String(j.text || ""));
    for (const i of S.items.values()) { const u = Date.parse(i.updated); if (!(when.get(i.id) || []).some(t => Math.abs(t - u) < 5000)) add(i.id, i.updated, i.by, "edited", "Edited"); }
    return ev.filter(e => e.text).sort((a, b) => a.at < b.at ? 1 : a.at > b.at ? -1 : 0);
  }
  // A history entry's changes as one line. Agents write entries too, so every value is escaped.
  function changeText(c) {
    const ch = k => Array.isArray(c[k]) && norm(k, c[k][0]) !== norm(k, c[k][1]) ? c[k] : null;
    const st = ch("status"), bl = ch("blockedBy"), pj = ch("project"), pr = ch("priority"), du = ch("due");
    const name = s => esc(STATUS[s] || s), out = [];
    if (st) out.push(st[1] === "waiting" ? `Blocked${bl && bl[1] ? ": " + esc(bl[1]) : ""}`
      : st[0] === "waiting" ? `Unblocked to ${name(st[1])}`
      : `${isOpen({ status: st[1] }) ? "Moved to " : ""}${name(st[1])}${st[0] ? ` <span class="hx">from ${name(st[0])}</span>` : ""}`);
    if (bl && !(st && (st[0] === "waiting" || st[1] === "waiting"))) out.push(bl[1] ? "Blocker: " + esc(bl[1]) : "Blocker cleared");
    if (pj) { const p = S.projects.get(pj[1]); out.push(p ? `Project <span class="proj"><i style="background:${esc(p.color)}"></i>${esc(p.name)}</span>` : pj[1] ? "Project changed" : "Project removed"); }
    if (pr) out.push(pr[1] ? "Priority P" + esc(pr[1]) : "Priority removed");
    if (du) out.push(du[1] ? "Due " + esc(fmtDay(String(du[1]))) : "Due date removed");
    for (const k of Object.keys(c)) if (!LOGGED.includes(k)) out.push("Changed " + esc(k));
    return out.join(" · ");
  }
  function renderHistory(ok) {
    const claude = e => e.by === "cli" || e.by === "phone";
    // Events in a row on one task from one source, within half an hour of each other, are one entry.
    // One whose source is unknown (a step created, then ticked by someone) joins an entry within 5 minutes.
    const all = [];
    for (const e of S.hist) {
      if (!ok.has(e.task)) continue;
      const g = all[all.length - 1], gap = g && new Date(g.last) - new Date(e.at);
      if (g && g.task === e.task && (g.by === e.by ? gap < 18e5 : (!e.by || !g.by) && gap < 3e5)) { g.ev.push(e); g.last = e.at; g.by = g.by || e.by; }
      else all.push({ task: e.task, by: e.by, at: e.at, last: e.at, ev: [e] });
    }
    const groups = all.filter(g => S.who === "all" || (S.who === "you" ? g.by === "page" : claude(g)));
    let h = `<div class="narrow"><div class="seg who" role="group" aria-label="Changes by">${[["all", "All"], ["claude", "Claude"], ["you", "You"]].map(([k, l]) => `<button data-who="${k}" aria-pressed="${S.who === k}">${l}</button>`).join("")}</div>`;
    if (!groups.length) return h + `<div class="empty"><strong>No changes yet</strong>${S.q || S.proj !== "all" || S.who !== "all" ? "Nothing matches this filter." : "What you and Claude change on tasks shows up here, newest first."}</div></div>`;
    let day = "";
    for (const g of groups.slice(0, S.histN)) {
      const d = localDay(new Date(g.at));
      if (d !== day) { h += `${day ? "</div>" : ""}<h2>${dayLabel(d)}</h2><div class="hday">`; day = d; }
      h += histRow(g, claude(g));
    }
    h += `</div>`;
    if (groups.length > S.histN) h += `<button class="btn2 hmore" data-hmore>Show older</button>`;
    return h + `</div>`;
  }
  function dayLabel(d) {
    const dt = new Date(d + "T12:00:00"), n = Math.round((new Date(localDay() + "T12:00:00") - dt) / 864e5);
    const full = esc(dt.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }));
    return n === 0 ? `Today <small>${full}</small>` : n === 1 ? `Yesterday <small>${full}</small>` : full;
  }
  // One entry: its task, who, and what happened, oldest first. Steps added or ticked in a row are one line.
  function histRow(g, byClaude) {
    // Sorting keeps ties in order, where reversing the newest-first list would flip them.
    const i = S.items.get(g.task), evs =[...g.ev].sort((a, b) => a.at < b.at ? -1 : a.at > b.at ? 1 : 0), lines = [];
    for (let k = 0; k < evs.length; k++) {
      const e = evs[k];
      if (e.kind === "step" || e.kind === "tick") {
        let n = k; while (n + 1 < evs.length && evs[n + 1].kind === e.kind) n++;
        const ts = evs.slice(k, n + 1).map(x => esc(x.text)), c = ts.length;
        lines.push(`${e.kind === "step" ? (c > 1 ? `Added ${c} steps` : "Added a step") : (c > 1 ? `Ticked ${c} steps` : "Ticked a step")}: ${ts.slice(0, 3).join(" · ")}${c > 3 ? " …" : ""}`);
        k = n; continue;
      }
      lines.push(e.kind === "session" ? `<span class="jk">Session</span>${inline(e.text)}` : e.kind === "note" ? `Note: ${inline(e.text)}` : e.text);
    }
    const time = new Date(g.at).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    const isNew = byClaude && g.at > S.histPrev;
    return `<div class="hg" data-htask="${esc(g.task)}"><div class="ht">${esc(time)}${isNew ? `<span class="hnew">New</span>` : ""}</div>
      <div class="hb"><div class="hh"><span class="htt">${esc(i.title || "Untitled")}</span>${g.by ? `<span class="hw">${esc(g.by === "page" ? "You" : SRC[g.by] || g.by)}</span>` : ""}</div>
      <ul class="hl">${lines.map(l => `<li>${l}</li>`).join("")}</ul></div></div>`;
  }
  // Entries past 90 days go, a few at a time, once per page load.
  async function prune() {
    const cut = new Date(Date.now() - KEEP).toISOString();
    for (const h of [...S.history.values()].filter(h => typeof h.at === "string" && h.at < cut).slice(0, 200)) {
      try { await S.db.doc("history/" + h.id).delete(); } catch (e) { return; }
    }
  }

  // ---------- sheet ----------
  // The main pane holds a task, or a step on its own. On a wide screen a step opened from its task
  // shows in a second pane to the left, so the task stays where it is.
  const pane = (el, name) => ({ el, name, id: null, kind: "item", pendingBlock: false, jAll: false, editLink: null, ub: null });
  const PM = pane($("#sheet"), "m"), PS = pane($("#side"), "s");
  const f = (P, sel) => P.el.querySelector(sel);
  const wide = () => window.matchMedia("(min-width: 1000px)").matches;
  function openSheet(id, kind = "item") {
    if (!(kind === "step" ? S.steps : S.items).has(id)) return;
    if (S.guideOpen) { saveGuide(); S.guideOpen = false; }
    closeSide(); if (PM.id) flushText(PM);
    PM.id = id; PM.kind = kind; mount(PM);
  }
  function openStep(id) {
    if (!wide() || PM.kind !== "item" || !PM.id) { openSheet(id, "step"); return; }
    if (!S.steps.has(id)) return;
    if (PS.id) flushText(PS);
    PS.id = id; PS.kind = "step"; mount(PS); refreshSheet(PM);
  }
  function closeSide() {
    if (!PS.id) return;
    flushText(PS); PS.id = null; PS.el.hidden = true; PS.el.innerHTML = "";
    if (PM.id) refreshSheet(PM);
  }
  function mount(P) {
    const sh = P.el;
    sh.innerHTML = `
      <div class="sh-top"><div class="crumb" id="crumb"></div><button class="x ref" id="shRef" title="Copy a line that tells Claude which task and step this is">Copy ref</button><button class="x" id="shClose">Close</button></div>
      <div class="sh-body">
        <textarea class="f-title" id="fTitle" rows="1" placeholder="Title"></textarea>
        <div class="props task-only">
          <label class="pill sel"><span class="pk">Status</span><select id="fStatus"></select></label>
          <label class="pill sel" id="fPrioPill"><span class="pk">Priority</span><select id="fPrio"><option value="0">None</option><option value="1">P1</option><option value="2">P2</option><option value="3">P3</option></select></label>
          <label class="pill sel" id="fProjPill"><i></i><span class="pk">Project</span><select id="fProj"></select></label>
          <label class="pill" id="fDuePill"><span class="pk">Due</span><input type="date" id="fDue"></label>
        </div>
        <div class="props step-only"><label class="pill donechk"><input type="checkbox" id="fDone"> Done</label><button class="pill dash" id="fMarkBlocked">Mark blocked</button></div>
        <div class="blocker" id="fBlockRow"><span class="tagw">Blocked</span><input id="fBlocked" placeholder="What does it wait on? One line." aria-label="Blocked by"><button class="mini" id="fUnblock" title="Clear the blocker and choose where the task goes">Unblock</button><button class="lk-x" id="fClearBlk" title="Clear blocker" aria-label="Clear blocker">&times;</button></div>
        <div class="unblock task-only" id="fUbForm" hidden>
          <div class="ub-h">Unblock<span id="fUbWas"></span></div>
          <input class="inp" id="fUbWhy" maxlength="200" placeholder="Why? Optional. Saved to the journal." aria-label="Why it is unblocked">
          <div class="ub-to" role="radiogroup" aria-label="Move to"><span class="pk">Move to</span>${UNBLOCK_TO.map(s => `<button type="button" role="radio" data-ubto="${s}" aria-checked="false">${STATUS[s]}</button>`).join("")}</div>
          <div class="np-act"><button type="button" class="btn2" id="fUbCancel">Cancel</button><button type="button" class="btn2 go" id="fUbGo">Unblock</button></div>
        </div>
        <section class="sec"><div class="sec-h"><h3>Notes</h3><button class="mini" data-edit="fNotes">Edit</button></div>
          <div class="md md-view" data-for="fNotes" tabindex="0" role="button" aria-label="Notes, press Enter to edit"></div>
          <textarea class="ta md-ta" id="fNotes" hidden placeholder="Context, decisions, next step. Markdown works."></textarea></section>
        <section class="sec task-only"><div class="sec-h"><h3>Steps</h3><small id="fStepN"></small></div>
          <div class="subs" id="fSubs"></div>
          <input class="add-row" id="fAddSub" placeholder="+ Add a step"></section>
        <section class="sec"><div class="sec-h"><h3>Links</h3></div>
          <ul class="links" id="fLinkList"></ul>
          <input class="add-row" id="fAddLink" placeholder="+ Paste a link"></section>
        <section class="sec task-only"><div class="sec-h"><h3>Journal</h3><small id="fJrN"></small><button class="mini" id="fJrAll" hidden></button></div>
          <ul class="jr" id="fJr"></ul></section>
        <details class="ho task-only" id="fHo"><summary>Handoff <small id="fHoMeta"></small></summary>
          <div class="ho-body">
            <div class="md md-view" data-for="fHandoff" tabindex="0" role="button" aria-label="Handoff, press Enter to edit"></div>
            <textarea class="ta md-ta mono-ta" id="fHandoff" hidden placeholder="A brief for whoever picks this up next: goal, state with exact references (repo, branch, commit, PR), what is verified, next steps in order, gotchas, how to run the checks."></textarea>
            <div class="ho-tools"><span class="hint">Claude writes this when you say "hand this off", and reads it when you say "pick up" this task.</span><span class="ho-btns"><button class="btn2" data-edit="fHandoff">Edit</button><button class="btn2" id="fHoCopy">Copy</button></span></div></div>
        </details>
        <div class="step-only"><button class="btn2 detach" id="fDetach">Make it a separate task</button></div>
        <div class="foot"><span id="fMeta"></span><button class="del" id="fDel">Delete</button></div>
      </div>`;
    sh.hidden = false; $("#scrim").hidden = false; P.pendingBlock = false; P.jAll = false; P.ub = null;
    const it = cur(P);
    f(P, "#fBlocked").value = it.blockedBy || ""; f(P, "#fHandoff").value = it.handoff || "";
    f(P, "#fTitle").value = it.title || ""; f(P, "#fNotes").value = it.notes || ""; f(P, "#fDue").value = it.due || "";
    grow(f(P, "#fTitle"));
    refreshSheet(P, true);
    if (S.readOnly) sh.querySelectorAll("input,textarea,select,button.pill,.mini,[data-edit],#fDel").forEach(e => e.disabled = true);
    if (!it.title) f(P, "#fTitle").focus();
  }
  let guideTimer = null, guideDirty = false;
  function openGuide() {
    if (PM.id) closeSheet();
    S.guideOpen = true;
    const sh = PM.el;
    sh.innerHTML = `
      <div class="sh-top"><div class="crumb">For agents</div><button class="x" id="shClose">Close</button></div>
      <div class="sh-body">
        <p class="hint" style="margin-top:0">Every Claude that uses this tracker reads this guide first, on any device. Edit it here; the change applies to the next agent that reads it.</p>
        <textarea class="ta guide-ta" id="gBody" placeholder="No guide yet."></textarea>
        <div class="foot"><span id="gMeta"></span></div>
      </div>`;
    sh.hidden = false; $("#scrim").hidden = false;
    $("#gBody").value = (S.guide && S.guide.body) || "";
    if (S.readOnly || !S.db) $("#gBody").disabled = true;
    refreshGuide();
  }
  function refreshGuide() {
    if (!S.guideOpen) return;
    const t = $("#gBody"), g = S.guide || {};
    if (t && t !== document.activeElement && !guideDirty && t.value !== (g.body || "")) t.value = g.body || "";
    const src = { page: "this page", cli: "Claude Code", phone: "Claude chat" };
    $("#gMeta").textContent = g.updated ? `Last change ${ago(g.updated)} via ${src[g.by] || g.by || "unknown"}.` : "";
  }
  function saveGuide() {
    clearTimeout(guideTimer); if (!guideDirty) return; guideDirty = false;
    const t = $("#gBody"); if (!t || !S.db || S.readOnly) return;
    const d = { body: t.value, updated: now(), by: "page" };
    S.guide = Object.assign({}, S.guide, d);
    if (S.guideExists) enqueue("meta/agent-guide", d); else { S.guideExists = true; create("meta/agent-guide", Object.assign({ title: "Worklog: guide for agents" }, d)); }
    refreshGuide();
  }
  function closeSheet() { if (S.guideOpen) { saveGuide(); S.guideOpen = false; } closeSide(); flushText(PM); PM.id = null; PM.kind = "item"; PM.el.hidden = true; $("#scrim").hidden = true; PM.el.innerHTML = ""; }

  function refreshSheet(P, first) {
    const it = cur(P); if (!it) { if (P === PS) closeSide(); else closeSheet(); return; }
    const sh = P.el, focused = document.activeElement;
    // Beside its task, a step needs no way back to it.
    const isStep = P.kind === "step", parent = isStep && P === PM && S.items.get(it.task);
    sh.querySelectorAll(".task-only").forEach(e => e.hidden = isStep);
    sh.querySelectorAll(".step-only").forEach(e => e.hidden = !isStep);
    f(P, "#fDone").checked = !!it.done;
    // The blocker line shows on a blocked task, on a step with a blocker, and while one is being written.
    const showBlk = P.pendingBlock || !!it.blockedBy || (!isStep && it.status === "waiting");
    f(P, "#fBlockRow").hidden = !showBlk; f(P, "#fMarkBlocked").hidden = showBlk;
    const canUb = !isStep && !S.readOnly && !!it.blockedBy && !P.pendingBlock;
    if (!canUb) P.ub = null;
    f(P, "#fUnblock").hidden = !canUb; f(P, "#fUbForm").hidden = !P.ub;
    // A step has no status or journal to ask about, so its blocker just clears.
    f(P, "#fClearBlk").hidden = !(isStep && !S.readOnly && it.blockedBy);
    if (P.ub) {
      f(P, "#fBlockRow").hidden = true; f(P, "#fUbWas").textContent = "was: " + it.blockedBy;
      P.el.querySelectorAll("[data-ubto]").forEach(b => b.setAttribute("aria-checked", String(b.dataset.ubto === P.ub.to)));
    }
    f(P, "#fHoMeta").textContent = it.handoff ? `written ${ago(it.handoffAt || it.updated)}${it.handoffBy === "cli" ? " by Claude Code" : ""}` : "none yet";
    f(P, "#crumb").innerHTML = parent ? `<span>Step of</span><button data-open="${esc(parent.id)}" title="${esc(parent.title || "Untitled")}">${esc(parent.title || "Untitled")}</button>` : isStep ? "Step" : "Task";
    // On a step the button goes back to its task; the scrim and Escape still close the panel.
    const x = f(P, "#shClose"); x.textContent = parent ? "Back" : "Close";
    if (parent) x.dataset.open = parent.id; else delete x.dataset.open;
    const shown = P.pendingBlock ? "waiting" : it.status;
    if (focused !== f(P, "#fStatus")) f(P, "#fStatus").innerHTML = Object.keys(STATUS).map(s => `<option value="${s}"${shown === s ? " selected" : ""}>${STATUS[s]}</option>`).join("");
    f(P, "#fPrio").value = String(it.priority || 0); f(P, "#fPrioPill").dataset.v = it.priority || 0;
    const pj = S.projects.get(it.project), pp = f(P, "#fProjPill");
    pp.classList.toggle("has", !!pj); pp.style.setProperty("--pc", pj ? pj.color : "transparent");
    const du = dueInfo(it); f(P, "#fDuePill").className = "pill" + (du ? " due-" + du.level : "");
    if (focused !== f(P, "#fProj")) f(P, "#fProj").innerHTML = projOptions(it.project);
    const kids = isStep ? [] : children(it.id);
    f(P, "#fSubs").innerHTML = kids.map(k => { const d = !!k.done; return `<div class="sub${d ? " d" : ""}${PS.id === k.id ? " on" : ""}"><input type="checkbox" data-check="${esc(k.id)}"${d ? " checked" : ""}${S.readOnly ? " disabled" : ""} aria-label="Done"><span data-ostep="${esc(k.id)}">${esc(k.title || "Untitled")}</span>${!d && k.blockedBy ? `<small class="tagw">Blocked</small>` : ""}</div>`; }).join("");
    f(P, "#fStepN").textContent = kids.length ? `${kids.filter(k => k.done).length}/${kids.length}` : "";
    if (!first) {
      for (const [sel, val] of [["#fTitle", it.title || ""], ["#fNotes", it.notes || ""], ["#fDue", it.due || ""], ["#fBlocked", it.blockedBy || ""], ["#fHandoff", it.handoff || ""]]) { const e = f(P, sel); if (e !== focused && !dirty[P.name + sel] && e.value !== val) e.value = val; }
      grow(f(P, "#fTitle"));
    }
    // While a link's description is being typed, a live update must not replace the field.
    const lin = f(P, ".lk-in");
    if (!(P.editLink != null && lin && lin === focused)) {
      f(P, "#fLinkList").innerHTML = (it.links || []).map((l, k) => linkRow(l, k, P.editLink === k)).join("");
      const e = f(P, ".lk-in"); if (e) e.focus();
    }
    renderMd(P, "fNotes"); renderMd(P, "fHandoff");
    if (!isStep) renderJournal(P, it.id);
    const src = { page: "this page", cli: "Claude Code", phone: "Claude chat" };
    f(P, "#fMeta").textContent = `Created ${fmtDay((it.created || "").slice(0, 10))}${it.source ? ` via ${src[it.source] || it.source}` : ""}. Last change ${ago(it.updated)} via ${src[it.by] || it.by || "unknown"}.`;
  }

  // debounced text fields
  const timers = {}, dirty = {};
  function textField(P, sel, key, transform) {
    const k = P.name + sel; dirty[k] = true; clearTimeout(timers[k]);
    timers[k] = setTimeout(() => commitText(P, sel, key, transform), sel === "#fHandoff" ? 1500 : 600);
  }
  function commitText(P, sel, key, transform) {
    const k = P.name + sel; clearTimeout(timers[k]); if (!dirty[k]) return; dirty[k] = false;
    const e = f(P, sel); if (!e || !P.id) return;
    const v = transform ? transform(e.value) : e.value;
    const it = cur(P); if (!it) return;
    if (JSON.stringify(it[key] == null ? "" : it[key]) === JSON.stringify(v)) return;
    if (key === "blockedBy") setBlocked(P, v);
    else if (key === "handoff") patch(P.id, { handoff: v, handoffAt: now(), handoffBy: "page" });
    else patchCur(P, { [key]: v });
  }
  function flushText(P) {
    if (!P.id) return;
    commitText(P, "#fTitle", "title", v => v.replace(/\s*\n\s*/g, " ").trim());
    commitText(P, "#fNotes", "notes");
    commitText(P, "#fBlocked", "blockedBy", oneLine); commitText(P, "#fHandoff", "handoff");
  }
  const oneLine = v => v.replace(/\s+/g, " ").trim();

  // ---------- helpers ----------
  function fmtDay(d) { if (!d) return ""; const dt = new Date(d + "T12:00:00"); if (isNaN(dt)) return d; const y = dt.getFullYear() !== new Date().getFullYear(); return dt.toLocaleDateString(undefined, { day: "numeric", month: "short", year: y ? "numeric" : undefined }); }
  function ago(iso) { if (!iso) return "at an unknown time"; const s = (Date.now() - new Date(iso)) / 1000; if (s < 60) return "just now"; if (s < 3600) return Math.round(s / 60) + " min ago"; if (s < 86400) return Math.round(s / 3600) + " h ago"; if (s < 7 * 86400) return Math.round(s / 86400) + " d ago"; return "on " + fmtDay(iso.slice(0, 10)); }
  // GitHub links read as "repo #123" with their kind; anything else as host and path.
  function linkInfo(u) {
    const g = u.match(/github\.com\/([^/]+)\/([^/?#]+)\/(pull|issues|discussions|commit|tree|blob)\/([^/?#]+)/);
    if (g) { const num = ["pull", "issues", "discussions"].includes(g[3]); return { kind: { pull: "PR", issues: "Issue", discussions: "Discussion", commit: "Commit", tree: "Branch", blob: "File" }[g[3]], label: num ? `${g[2]} #${g[4]}` : `${g[2]} ${g[3] === "commit" ? g[4].slice(0, 7) : g[4]}`, host: g[1] }; }
    try { const x = new URL(u); return { kind: "Link", label: (x.host.replace(/^www\./, "") + x.pathname).replace(/\/$/, ""), host: "" }; } catch (e) { return { kind: "Text", label: u, host: "" }; }
  }
  // A described link shows its description; the URL is in the tooltip.
  function linkRow(l, k, editing) {
    const u = lurl(l), d = ltitle(l), li = linkInfo(u), kind = `<span class="lk-k">${esc(li.kind)}</span>`;
    if (editing) return `<li class="lk"><span class="lk-a">${kind}<input class="lk-in" data-ldesc="${k}" value="${esc(d)}" maxlength="120" placeholder="What is this link? Enter saves, Esc skips" aria-label="Link description"></span></li>`;
    const body = `${kind}<span class="lk-t">${esc(d || li.label)}</span>`;
    return `<li class="lk">${/^https?:\/\//.test(u) ? `<a href="${esc(u)}" target="_blank" rel="noopener" draggable="false" title="${esc(d ? d + "\n" + u : u)}">${body}</a>` : `<span class="lk-a">${body}</span>`}${S.readOnly ? "" : `<button class="lk-x lk-e" data-ledit="${k}" aria-label="Describe link" title="Describe">&#9998;</button><button class="lk-x" data-unlink="${k}" aria-label="Remove link">&times;</button>`}</li>`;
  }
  // Takes anything pasted: several links at once, and bare domains get https://.
  function addLinks(P, text) {
    const add = text.split(/\s+/).filter(Boolean).map(s => /^https?:\/\//i.test(s) ? s : /^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(s) ? "https://" + s : null).filter(Boolean);
    const it = cur(P); if (!it || !add.length) return false;
    const have = it.links || [], urls = have.map(lurl), fresh = add.filter(u => !urls.includes(u));
    // A new link asks for its description straight away.
    if (fresh.length) { P.editLink = have.length; patchCur(P, { links: [...have, ...fresh] }); }
    return true;
  }
  function setLinkTitle(P, k, v) {
    const it = cur(P), links = [...((it && it.links) || [])]; if (k >= links.length || ltitle(links[k]) === v) return;
    links[k] = v ? { url: lurl(links[k]), title: v } : lurl(links[k]);
    patchCur(P, { links });
  }
  function endLinkEdit(P, input, save) {
    const k = +input.dataset.ldesc; if (P.editLink !== k) return;
    P.editLink = null;
    if (save) setLinkTitle(P, k, input.value.trim());
    refreshSheet(P);
  }
  function removeLink(P, k) {
    const it = cur(P); if (!it) return;
    const was = it.links || [], id = P.id, kind = P.kind;
    patchCur(P, { links: was.filter((_, j) => j !== k) });
    toast("Link removed.", () => (kind === "step" ? patchStep : patch)(id, { links: was }));
  }

  // Small Markdown: headings, lists, checkboxes, fenced and inline code, bold, italic, links, rules.
  function inline(s) {
    // Code spans and links are cut out first, so nothing inside them is formatted.
    const keep = [], hold = h => `\u0000${keep.push(h) - 1}\u0000`;
    s = s.replace(/`([^`]+)`/g, (_, c) => hold(`<code>${esc(c)}</code>`))
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, (_, t, u) => hold(`<a href="${esc(u)}" target="_blank" rel="noopener">${esc(t)}</a>`))
      .replace(/https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"]/g, u => hold(`<a href="${esc(u)}" target="_blank" rel="noopener">${esc(linkInfo(u).label)}</a>`));
    return esc(s).replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^\w*])[*_]([^*_\s][^*_]*?)[*_](?![\w*])/g, "$1<em>$2</em>")
      .replace(/\u0000(\d+)\u0000/g, (_, k) => keep[+k]);
  }
  // A line opening with "Verified", "Inferred", "Assumed" or "Not run" gets a label, as in a handoff's evidence section.
  const EV = { verified: "ok", inferred: "warn", assumed: "bad", "not run": "bad", "not verified": "bad" };
  function evid(s) {
    const m = s.match(/^\*{0,2}(verified|inferred|assumed|not run|not verified)\b([^:*]*)\*{0,2}:\*{0,2}\s*(.*)$/i);
    if (!m || /inferred|assumed/i.test(m[2])) return inline(s);
    const q = m[2].replace(/^[\s,]+/, "").trim();
    return `<span class="ev ${EV[m[1].toLowerCase()]}">${esc(m[1])}</span>${q ? `<em class="ev-q">${esc(q)}:</em> ` : ""}${inline(m[3])}`;
  }
  function copyText(v, done) {
    (navigator.clipboard ? navigator.clipboard.writeText(v) : Promise.reject()).then(() => toast(done), () => toast(v.length < 200 ? "Copy isn't available here. Select it: " + v : "Copy isn't available here. Select the text and press Cmd+C."));
  }
  // The journal: agent sessions (with how to resume them) and one-line notes, newest first.
  const shq = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
  // A session in an agentctl sandbox comes back by attaching to it from the host it was applied on.
  const resumeCmd = j => j.agent && j.agentSession
    ? `cd ${shq(j.cwd)} && agentctl attach ${shq("session/" + j.agentSession)} --agent ${shq(j.agent)}`
    : `cd ${shq(j.cwd)} && claude --resume ${j.session}`;
  // What "Copy ref" copies: the ids an agent reads, with titles so a wrong paste is obvious (agent guide).
  function refText(P) {
    const it = cur(P); if (!it) return "";
    const q = s => `"${(s || "Untitled").replace(/"/g, "'")}"`;
    if (P.kind !== "step") return `Worklog: ${P.id} ${q(it.title)}`;
    const task = S.items.get(it.task);
    return `Worklog: ${it.task}${task ? " " + q(task.title) : ""}\n› step ${P.id} ${q(it.title)}`;
  }
  function renderJournal(P, id) {
    const all = journalOf(id), shown = P.jAll ? all : all.slice(0, 5);
    f(P, "#fJrN").textContent = all.length ? String(all.length) : "";
    const b = f(P, "#fJrAll"); b.hidden = all.length <= 5; b.textContent = P.jAll ? "Show fewer" : `Show all ${all.length}`;
    f(P, "#fJr").innerHTML = shown.length ? shown.map(j => {
      const ses = j.kind === "session";
      const meta = [ago(j.at), SRC[j.by] || j.by, ses && j.host, ses && j.agent && j.agentSession && `${j.agent}/${j.agentSession}`, ses && j.branch].filter(Boolean).map(x => `<span>${esc(x)}</span>`).join("");
      const resume = ses && j.cwd && (j.session || (j.agent && j.agentSession)) ?`<button class="btn2 sm" data-resume="${esc(j.id)}" title="${esc(resumeCmd(j))}">Resume</button>` : "";
      return `<li class="je"><div class="je-t">${ses ? `<span class="jk">Session</span>` : ""}${inline(j.text || "")}</div><div class="je-m">${meta}</div><div class="je-a">${resume}${S.readOnly ? "" : `<button class="lk-x" data-unjournal="${esc(j.id)}" aria-label="Delete entry">&times;</button>`}</div></li>`;
    }).join("") : `<li class="je-empty">Agents add a line here when they start on this task, with a command to resume their session.</li>`;
  }
  function deleteJournal(id) {
    const j = S.journal.get(id); if (!j || S.readOnly) return;
    S.journal.delete(id); S.db.doc("journal/" + id).delete().catch(writeErr); render();
    const data = Object.assign({}, j); delete data.id;
    toast("Entry deleted.", () => { S.journal.set(id, j); create("journal/" + id, data); render(); });
  }
  function md(src) {
    const lines = String(src || "").replace(/\r/g, "").split("\n");
    let h = "", list = null, para = [];
    const endP = () => { if (para.length) { h += `<p>${para.map(evid).join("<br>")}</p>`; para = []; } };
    const endL = () => { if (list) { h += `<${list.t}>${list.items.map(x => `<li>${x}</li>`).join("")}</${list.t}>`; list = null; } };
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i]; let m;
      if (/^\s*```/.test(l)) {
        endP(); endL(); const code = [];
        while (++i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i]);
        h += `<pre><code>${esc(code.join("\n"))}</code><button class="cp" type="button" data-copy>Copy</button></pre>`;
      } else if ((m = l.match(/^(#{1,6})\s+(.*)$/))) { endP(); endL(); const n = Math.min(6, m[1].length + 3); h += `<h${n}>${inline(m[2])}</h${n}>`; }
      else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)) { endP(); endL(); h += "<hr>"; }
      else if ((m = l.match(/^\s*([-*+]|\d+[.)])\s+(.*)$/))) {
        endP(); const t = /\d/.test(m[1]) ? "ol" : "ul";
        if (!list || list.t !== t) { endL(); list = { t, items: [] }; }
        const cb = m[2].match(/^\[([ xX])\]\s+(.*)$/);
        list.items.push(cb ? `<span class="cb${cb[1] === " " ? "" : " on"}"></span>${inline(cb[2])}` : evid(m[2]));
      } else if (!l.trim()) { endP(); endL(); }
      else if (list && /^\s{2,}\S/.test(l)) list.items[list.items.length - 1] += " " + inline(l.trim());
      else { endL(); para.push(l); }
    }
    endP(); endL();
    return h;
  }
  const MD_EMPTY = { fNotes: "Add notes", fHandoff: "No handoff yet. Claude writes one when you say \"hand this off\"." };
  const mdView = (P, id) => f(P, `.md-view[data-for="${id}"]`);
  function renderMd(P, id) {
    const ta = f(P, "#" + id), v = mdView(P, id); if (!ta || !v || !ta.hidden) return;
    v.innerHTML = ta.value.trim() ? md(ta.value) : `<span class="md-empty">${esc(MD_EMPTY[id])}</span>`;
  }
  function editMd(P, id) {
    const ta = f(P, "#" + id), v = mdView(P, id); if (!ta || S.readOnly) return;
    if (id === "fHandoff") f(P, "#fHo").open = true;
    v.hidden = true; ta.hidden = false; fit(ta); ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length);
  }
  function doneMd(P, id) { const ta = f(P, "#" + id); if (!ta || ta.hidden) return; ta.hidden = true; mdView(P, id).hidden = false; renderMd(P, id); }
  function fit(t) { t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight + 2, Math.max(220, window.innerHeight * .6)) + "px"; }
  // Choosing Blocked asks for the blocker first; writing it moves the task (setBlocked).
  function askBlocker(P) { P.pendingBlock = true; refreshSheet(P); f(P, "#fBlocked").focus(); }
  function grow(t) { t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 160) + "px"; }
  let tt; function toast(msg, undo) {
    const t = $("#toast"); t.innerHTML = esc(msg) + (undo ? `<button class="undo">Undo</button>` : ""); t.hidden = false;
    t.onclick = undo ? e => { if (e.target.closest(".undo")) { undo(); t.hidden = true; } } : null;
    clearTimeout(tt); tt = setTimeout(() => t.hidden = true, undo ? 6000 : 3200);
  }

  // ---------- events ----------
  document.querySelector(".tabs").addEventListener("click", e => {
    const b = e.target.closest(".tab"); if (!b) return;
    // Opening History marks what arrived since your last visit; render() then moves `seen` along.
    if (b.dataset.view === "history" && S.view !== "history") { S.histPrev = S.seen; S.histN = HIST_PAGE; }
    S.view = b.dataset.view; try { localStorage.setItem("wl.view", S.view); } catch (x) {} window.scrollTo(0, 0); render(); });
  $("#q").addEventListener("input", e => { S.q = e.target.value.trim().toLowerCase(); render(); });
  $("#chips").addEventListener("click", e => {
    const b = e.target.closest("[data-proj]");
    if (b) {
      const id = b.dataset.proj, editing = S.npOpen && S.npEdit === id;
      closeProject();
      if (id === S.proj && S.projects.has(id) && S.db && !S.readOnly) { if (!editing) openProject(b, id); return; }
      S.proj = id; render(); return;
    }
    const ap = e.target.closest("[data-addproj]"); if (ap) { const was = S.npOpen && !S.npEdit; closeProject(); if (!was) openProject(ap); }
  });
  const np = $("#np");
  np.addEventListener("click", e => {
    const sw = e.target.closest("[data-color]");
    if (sw) { S.npColor = sw.dataset.color; np.querySelectorAll("[data-color]").forEach(b => b.setAttribute("aria-checked", String(b === sw))); $("#npName").focus(); return; }
    if (e.target.closest("[data-npcancel]")) closeProject();
    if (e.target.id === "npGo") saveProject();
    if (e.target.id === "npArch") setProjectStatus(S.npEdit, "archived");
    if (e.target.id === "npRestore") setProjectStatus(S.npEdit, "active");
    if (e.target.id === "npDel") {
      const t = e.target, n = tasks().filter(i => i.project === S.npEdit).length;
      if (t.classList.contains("arm")) { deleteProject(S.npEdit); return; }
      t.classList.add("arm"); t.textContent = n ? `Delete? ${n} task${n > 1 ? "s" : ""} move to No project` : "Click again to delete";
    }
  });
  np.addEventListener("input", e => { if (e.target.id === "npName") $("#npGo").disabled = !e.target.value.trim(); });
  np.addEventListener("keydown", e => {
    if (e.key === "Escape") { e.stopPropagation(); closeProject(); }
    if (e.key === "Enter" && e.target.id === "npName" && !e.isComposing) { e.preventDefault(); saveProject(); }
  });
  // A click elsewhere, or scrolling the chip row, closes it. Not resize: a phone keyboard resizes the window.
  document.addEventListener("pointerdown", e => { if (S.npOpen && !e.target.closest("#np, #chips button")) closeProject(); });
  $("#chips").addEventListener("scroll", closeProject);

  $("#main").addEventListener("change", e => {
    const t = e.target; if (t.dataset.check) setStepDone(t.dataset.check, t.checked);
    // Blur first: render() holds the cards back while a project list has focus.
    if (t.dataset.setproj) { t.blur(); patch(t.dataset.setproj, { project: t.value }); }
  });
  // A live update held back while a project list was open renders once it closes.
  $("#main").addEventListener("focusout", e => { if (e.target.dataset && e.target.dataset.setproj) setTimeout(render); });
  $("#main").addEventListener("click", e => {
    if (e.target.closest("[data-check], .tproj")) return;
    const tg = e.target.closest("[data-toggle]");
    if (tg) { const id = tg.dataset.toggle; if (S.expanded.has(id)) S.expanded.delete(id); else S.expanded.add(id); saveExpanded(); render(); return; }
    const so = e.target.closest(".steps [data-ostep]"); if (so) { openSheet(so.dataset.ostep, "step"); return; }
    if (e.target.closest(".steps")) return;
    const mv = e.target.closest("[data-move]");
    if (mv) { const id = mv.closest(".card").dataset.id; setStatus(id, mv.dataset.move); toast(`Moved to ${STATUS[mv.dataset.move]}.`); return; }
    const col = e.target.closest("[data-col]");
    if (col) { S.col = col.dataset.col; try { localStorage.setItem("wl.col", S.col); } catch (x) {} render(); return; }
    const sk = e.target.closest("[data-stack]");
    if (sk) { S.proj = sk.dataset.stack; window.scrollTo(0, 0); render(); return; }
    const wh = e.target.closest("[data-who]"); if (wh) { S.who = wh.dataset.who; S.histN = HIST_PAGE; render(); return; }
    if (e.target.closest("[data-hmore]")) { S.histN += HIST_PAGE; render(); return; }
    const hg = e.target.closest("[data-htask]"); if (hg) { if (!e.target.closest("a")) openSheet(hg.dataset.htask); return; }
    const c = e.target.closest(".card"); if (c) openSheet(c.dataset.id);
  });

  const cap = $("#cap"), capBtn = $("#capBtn");
  function capture() {
    const v = cap.value.trim(); if (!v || !S.db) return;
    const [first, ...rest] = v.split("\n");
    addItem({ title: first.trim(), notes: rest.join("\n").trim(), project: S.proj !== "all" && S.proj !== "none" ? S.proj : "" });
    cap.value = ""; grow(cap); capBtn.disabled = true;
    toast(S.view === "inbox" ? "Added." : "Added to Inbox.");
  }
  cap.addEventListener("input", () => { grow(cap); capBtn.disabled = !cap.value.trim() || !S.db || S.readOnly; });
  cap.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); capture(); } });
  capBtn.addEventListener("click", capture);

  // ---------- drag between board columns ----------
  // A mouse drag starts after a few pixels of movement; a touch drag after a short hold, so a swipe
  // still scrolls. On a phone the board shows one column, so the column tabs are the drop targets.
  let D = null, scrollRaf = 0, swallowClick = false;
  const dropAt = (x, y) => { const el = document.elementFromPoint(x, y), t = el && el.closest(".board .col, .seg [data-col]"); return t ? { el: t, s: t.dataset.s || t.dataset.col } : null; };
  $("#main").addEventListener("pointerdown", e => {
    if (S.view !== "board" || S.readOnly || e.button !== 0) return;
    const c = e.target.closest(".board .card[data-id]"); if (!c || e.target.closest("button, input, a, .steps")) return;
    D = { id: c.dataset.id, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY, pid: e.pointerId, touch: e.pointerType !== "mouse", active: false };
    if (D.touch) D.timer = setTimeout(() => { if (D) startDrag(); }, 350);
  });
  function startDrag() {
    const card = $(`.board .card[data-id="${CSS.escape(D.id)}"]`); if (!card) { D = null; return; }
    const r = card.getBoundingClientRect();
    Object.assign(D, { active: true, card, dx: D.x - r.left, dy: D.y - r.top, ghost: card.cloneNode(true), line: document.createElement("div") });
    D.origIdx = [...card.closest(".col").querySelectorAll(".card[data-id]")].indexOf(card); D.line.className = "drop-line";
    D.ghost.classList.add("ghost"); D.ghost.style.width = r.width + "px"; D.ghost.removeAttribute("data-id");
    document.body.appendChild(D.ghost); card.classList.add("dragging"); document.body.classList.add("dragging");
    moveDrag();
  }
  function moveDrag() {
    D.ghost.style.transform = `translate(${D.x - D.dx}px, ${D.y - D.dy}px) rotate(1.5deg)`;
    const t = dropAt(D.x, D.y);
    if (D.over && (!t || D.over.el !== t.el)) D.over.el.classList.remove("drop");
    D.over = t; if (t) t.el.classList.add("drop");
    // Within a column, a line shows where the card lands. A column tab has no position: the card goes on top.
    if (!t || !t.el.classList.contains("col")) { D.line.remove(); return; }
    const cards = [...t.el.querySelectorAll(".card[data-id]:not(.dragging)")], top = t.el.getBoundingClientRect().top;
    let i = cards.findIndex(c => { const r = c.getBoundingClientRect(); return D.y < r.top + r.height / 2; });
    if (i < 0) i = cards.length;
    t.idx = i; t.ids = cards.map(c => c.dataset.id);
    const ref = cards[i], last = cards[cards.length - 1];
    const y = ref ? ref.getBoundingClientRect().top - 5 : last ? last.getBoundingClientRect().bottom + 3 : t.el.querySelector(".list").getBoundingClientRect().top;
    D.line.style.top = (y - top) + "px";
    if (D.line.parentNode !== t.el) t.el.appendChild(D.line);
  }
  // The dropped card's rank sits between its new neighbours. A column that still has unranked cards
  // is numbered first, in the order it shows. Ranks change no `updated`: reordering is not an edit.
  function setRank(id, rank) { const it = S.items.get(id); if (!it || S.readOnly) return; S.items.set(id, Object.assign({}, it, { rank })); enqueue("items/" + id, { rank }); }
  function rankAt(ids, i) {
    const its = ids.map(id => S.items.get(id)).filter(Boolean);
    if (its.some(x => !ranked(x))) its.forEach((x, k) => setRank(x.id, k + 1));
    const r = k => S.items.get(its[k].id).rank;
    return !its.length ? 1 : i <= 0 ? r(0) - 1 : i >= its.length ? r(its.length - 1) + 1 : (r(i - 1) + r(i)) / 2;
  }
  function autoScroll() {
    cancelAnimationFrame(scrollRaf);
    const edge = 70, top = $(".top").getBoundingClientRect().bottom, bot = window.innerHeight - $(".capture").offsetHeight;
    const v = D.y < top + edge ? -(top + edge - D.y) / 4 : D.y > bot - edge ? (D.y - bot + edge) / 4 : 0;
    if (!v) return;
    const step = () => { if (!D || !D.active) return; window.scrollBy(0, Math.max(-18, Math.min(18, v))); moveDrag(); scrollRaf = requestAnimationFrame(step); };
    scrollRaf = requestAnimationFrame(step);
  }
  function endDrag(drop) {
    const d = D; D = null; clearTimeout(d.timer); cancelAnimationFrame(scrollRaf);
    if (!d.active) return;
    d.ghost.remove(); d.line.remove(); d.card.classList.remove("dragging"); document.body.classList.remove("dragging");
    if (d.over) d.over.el.classList.remove("drop");
    swallowClick = true; setTimeout(() => { swallowClick = false; }, 0);
    const o = drop && d.over, it = o && S.items.get(d.id);
    if (!it) { render(); return; }
    const to = o.s, same = it.status === to;
    if (same && (o.idx == null || o.idx === d.origIdx)) { render(); return; }
    // Waiting always has a blocker: ask for it, and setBlocked moves the task once it is written.
    if (to === "waiting" && !it.blockedBy) { render(); openSheet(it.id); askBlocker(PM); toast("Write what blocks it to move it to Blocked."); return; }
    const rank = o.idx == null ? null : rankAt(o.ids, o.idx);
    if (same) { setRank(it.id, rank); render(); return; }
    // A blocker goes with the move, except into Blocked: a task waiting on you now waits on someone else.
    const clear = !!it.blockedBy && to !== "waiting", data = { status: to, doneAt: "", rank };
    if (clear) data.blockedBy = "";
    patch(it.id, data);
    toast(`Moved to ${STATUS[to]}.${clear ? " Blocker cleared." : ""}`, () => patch(it.id, { status: it.status, blockedBy: it.blockedBy || "", doneAt: it.doneAt || "", rank: ranked(it) ? it.rank : null }));
  }
  document.addEventListener("pointermove", e => {
    if (!D || e.pointerId !== D.pid) return;
    D.x = e.clientX; D.y = e.clientY;
    if (D.active) { moveDrag(); autoScroll(); return; }
    if (Math.hypot(D.x - D.x0, D.y - D.y0) > (D.touch ? 8 : 5)) { if (D.touch) { clearTimeout(D.timer); D = null; } else startDrag(); }
  });
  document.addEventListener("pointerup", e => { if (D && e.pointerId === D.pid) endDrag(true); });
  document.addEventListener("pointercancel", e => { if (D && e.pointerId === D.pid) endDrag(false); });
  document.addEventListener("touchmove", e => { if (D && D.active) e.preventDefault(); }, { passive: false });
  document.addEventListener("contextmenu", e => { if (D) e.preventDefault(); });
  document.addEventListener("click", e => { if (swallowClick) { swallowClick = false; e.stopPropagation(); e.preventDefault(); } }, true);
  document.addEventListener("keydown", e => { if (e.key === "Escape" && D && D.active) endDrag(false); });

  // ---------- reorder steps and links in the sheet ----------
  // The same gestures as the board. Dropped steps are numbered 1…n in their new order; links are
  // written back as one array. Like a board rank, a new order changes no `updated`.
  let R = null;
  const rowsOf = list => [...list.children].filter(r => r.matches(".sub, .lk"));
  for (const P of [PM, PS]) P.el.addEventListener("pointerdown", e => {
    if (S.readOnly || e.button !== 0 || D || R) return;
    const row = e.target.closest("#fSubs > .sub, #fLinkList > .lk");
    if (!row || e.target.closest("input, button") || rowsOf(row.parentNode).length < 2) return;
    const it = cur(P); if (!it) return;
    R = { P, row, list: row.parentNode, links: row.matches(".lk") && it.links, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY, pid: e.pointerId, touch: e.pointerType !== "mouse", active: false };
    if (R.touch) R.timer = setTimeout(() => { if (R) startReorder(); }, 350);
  });
  function startReorder() {
    const rows = rowsOf(R.list), r = R.row.getBoundingClientRect();
    Object.assign(R, { active: true, from: rows.indexOf(R.row), to: rows.indexOf(R.row), left: r.left, dy: R.y - r.top, ghost: R.row.cloneNode(true), line: document.createElement("div") });
    R.line.className = "drop-line"; R.ghost.classList.add("ghost"); R.ghost.style.width = r.width + "px";
    document.body.appendChild(R.ghost); R.row.classList.add("dragging"); document.body.classList.add("dragging");
    moveReorder();
  }
  function moveReorder() {
    R.ghost.style.transform = `translate(${R.left}px, ${R.y - R.dy}px)`;
    const rows = rowsOf(R.list).filter(r => r !== R.row);
    let i = rows.findIndex(r => { const b = r.getBoundingClientRect(); return R.y < b.top + b.height / 2; });
    if (i < 0) i = rows.length;
    R.to = i;
    const y = i < rows.length ? rows[i].getBoundingClientRect().top - 1 : rows[rows.length - 1].getBoundingClientRect().bottom;
    R.line.style.top = (y - R.list.getBoundingClientRect().top) + "px";
    if (!R.line.parentNode) R.list.appendChild(R.line);
  }
  const moved = (a, from, to) => { const b = [...a]; b.splice(to, 0, ...b.splice(from, 1)); return b; };
  function endReorder(drop) {
    const r = R; R = null; clearTimeout(r.timer);
    if (!r.active) return;
    r.ghost.remove(); r.line.remove(); r.row.classList.remove("dragging"); document.body.classList.remove("dragging");
    swallowClick = true; setTimeout(() => { swallowClick = false; }, 0);
    const it = cur(r.P);
    if (drop && it && r.to !== r.from) {
      if (r.links) {
        // A link added, removed or described by someone else mid-drag would make the positions wrong.
        if (JSON.stringify(it.links) !== JSON.stringify(r.links)) toast("The links changed while you dragged. Try again.");
        else { const links = moved(it.links, r.from, r.to), map = r.P.kind === "step" ? S.steps : S.items; map.set(r.P.id, Object.assign({}, it, { links })); enqueue((r.P.kind === "step" ? "steps/" : "items/") + r.P.id, { links }); }
      } else {
        // Steps go by the ids on screen; one added mid-drag keeps its place at the end.
        const ids = moved(rowsOf(r.list).map(x => x.querySelector("[data-ostep]").dataset.ostep), r.from, r.to);
        const kids = children(it.id), order = [...ids.map(id => kids.find(k => k.id === id)).filter(Boolean), ...kids.filter(k => !ids.includes(k.id))];
        order.forEach((k, n) => { if (k.order !== n + 1) { S.steps.set(k.id, Object.assign({}, k, { order: n + 1 })); enqueue("steps/" + k.id, { order: n + 1 }); } });
      }
    }
    render();
  }
  document.addEventListener("pointermove", e => {
    if (!R || e.pointerId !== R.pid) return;
    R.x = e.clientX; R.y = e.clientY;
    if (R.active) { moveReorder(); return; }
    if (Math.hypot(R.x - R.x0, R.y - R.y0) > (R.touch ? 8 : 5)) { if (R.touch) { clearTimeout(R.timer); R = null; } else startReorder(); }
  });
  document.addEventListener("pointerup", e => { if (R && e.pointerId === R.pid) endReorder(true); });
  document.addEventListener("pointercancel", e => { if (R && e.pointerId === R.pid) endReorder(false); });
  document.addEventListener("touchmove", e => { if (R && R.active) e.preventDefault(); }, { passive: false });
  document.addEventListener("contextmenu", e => { if (R) e.preventDefault(); });
  // Escape drops nothing and leaves the panel open.
  window.addEventListener("keydown", e => { if (e.key === "Escape" && R && R.active) { e.stopPropagation(); endReorder(false); } }, true);

  // "/" jumps to search and "N" to capture, unless you are typing or a sheet is open.
  document.addEventListener("keydown", e => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing || PM.id || S.guideOpen || S.npOpen) return;
    if (e.target.closest && e.target.closest("input, textarea, select, [contenteditable]")) return;
    if (e.key === "/") { e.preventDefault(); $("#q").focus(); }
    else if (e.key === "n" || e.key === "N") { e.preventDefault(); $("#cap").focus(); }
  });
  function isoWeek(d) { const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())); t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7)); return Math.ceil(((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 864e5 + 1) / 7); }
  const d0 = new Date();
  $("#stamp").textContent = `W${isoWeek(d0)} · ${d0.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}`;

  $("#scrim").addEventListener("click", closeSheet);
  // Escape closes the step beside a task first, then the task.
  document.addEventListener("keydown", e => { if (e.key !== "Escape") return; if (PS.id) closeSide(); else if (PM.id || S.guideOpen) closeSheet(); });
  window.addEventListener("resize", () => { if (PS.id && !wide()) closeSide(); });
  $("#guideBtn").addEventListener("click", openGuide);
  for (const P of [PM, PS]) {
    const sh = P.el;
    sh.addEventListener("click", e => {
      const t = e.target;
      if (t.id === "shClose" && !t.dataset.open) return P === PS ? closeSide() : closeSheet();
      if (t.id === "shRef") { copyText(refText(P), "Reference copied. Paste it to Claude."); return; }
      const op = t.closest("[data-open]"); if (op) { openSheet(op.dataset.open); return; }
      // Clicking the step that is already open beside its task closes it again.
      const os = t.closest("[data-ostep]"); if (os) { if (P === PM && PS.id === os.dataset.ostep) closeSide(); else openStep(os.dataset.ostep); return; }
      const cp = t.closest("[data-copy]"); if (cp) { copyText(cp.parentNode.querySelector("code").textContent, "Copied."); return; }
      const rs = t.closest("[data-resume]"); if (rs) { const j = S.journal.get(rs.dataset.resume); if (j) copyText(resumeCmd(j), "Resume command copied. Paste it in a terminal."); return; }
      const uj = t.closest("[data-unjournal]"); if (uj) { deleteJournal(uj.dataset.unjournal); return; }
      if (t.id === "fJrAll") { P.jAll = !P.jAll; renderJournal(P, P.id); return; }
      const ed = t.closest("[data-edit]"); if (ed) { editMd(P, ed.dataset.edit); return; }
      const mv = t.closest(".md-view"); if (mv && !t.closest("a")) { editMd(P, mv.dataset.for); return; }
      const le = t.closest("[data-ledit]"); if (le) { P.editLink = +le.dataset.ledit; refreshSheet(P); return; }
      const ul = t.closest("[data-unlink]"); if (ul) { removeLink(P, +ul.dataset.unlink); return; }
      if (t.id === "fMarkBlocked") { askBlocker(P); return; }
      if (t.id === "fUnblock") { P.ub = { to: "next" }; refreshSheet(P); const w = f(P, "#fUbWhy"); w.value = ""; w.focus(); return; }
      if (t.id === "fUbCancel") { P.ub = null; refreshSheet(P); return; }
      const ubt = t.closest("[data-ubto]"); if (ubt && P.ub) { P.ub.to = ubt.dataset.ubto; refreshSheet(P); return; }
      if (t.id === "fUbGo") { unblock(P); return; }
      if (t.id === "fClearBlk") {
        const st = cur(P), was = st && st.blockedBy, id = P.id; if (!was) return;
        dirty[P.name + "#fBlocked"] = false; clearTimeout(timers[P.name + "#fBlocked"]);
        patchStep(id, { blockedBy: "" });
        toast("Blocker cleared.", () => patchStep(id, { blockedBy: was }));
        return;
      }
      if (t.id === "fDetach") { flushText(P); detachStep(P.id); return; }
      if (t.id === "fHoCopy") {
        const v = f(P, "#fHandoff").value;
        if (!v.trim()) { toast("Nothing to copy yet."); return; }
        (navigator.clipboard ? navigator.clipboard.writeText(v) : Promise.reject()).then(() => toast("Handoff copied."), () => { editMd(P, "fHandoff"); f(P, "#fHandoff").select(); toast("Press Ctrl+C or Cmd+C to copy."); });
        return;
      }
      if (t.id === "fDel") {
        if (t.classList.contains("arm")) { if (P.kind === "step") deleteStep(P.id); else deleteItem(P.id); return; }
        t.classList.add("arm"); t.textContent = "Tap again to delete"; setTimeout(() => { if (t.isConnected) { t.classList.remove("arm"); t.textContent = "Delete"; } }, 3000);
      }
    });
    sh.addEventListener("change", e => {
      const t = e.target;
      if (t.dataset.check) { setStepDone(t.dataset.check, t.checked); return; }
      if (t.id === "fDone") { setStepDone(P.id, t.checked); return; }
      if (t.id === "fStatus") { if (t.value === "waiting" && !cur(P).blockedBy) askBlocker(P); else { P.pendingBlock = false; setStatus(P.id, t.value); } return; }
      if (t.id === "fPrio") patch(P.id, { priority: +t.value });
      if (t.id === "fProj") patch(P.id, { project: t.value });
      if (t.id === "fDue") patch(P.id, { due: t.value });
    });
    sh.addEventListener("input", e => {
      const t = e.target;
      if (t.id === "fTitle") { grow(t); textField(P, "#fTitle", "title", v => v.replace(/\s*\n\s*/g, " ").trim()); }
      if (t.id === "fNotes") { fit(t); textField(P, "#fNotes", "notes"); }
      if (t.id === "fBlocked") textField(P, "#fBlocked", "blockedBy", oneLine);
      if (t.id === "gBody") { guideDirty = true; clearTimeout(guideTimer); guideTimer = setTimeout(saveGuide, 1500); }
      if (t.id === "fHandoff") { fit(t); textField(P, "#fHandoff", "handoff"); }
    });
    sh.addEventListener("focusout", e => {
      const id = e.target.id;
      if (e.target.classList.contains("lk-in")) endLinkEdit(P, e.target, true);
      if (id === "fTitle") commitText(P, "#fTitle", "title", v => v.replace(/\s*\n\s*/g, " ").trim());
      if (id === "fNotes") { commitText(P, "#fNotes", "notes"); doneMd(P, "fNotes"); }
      if (id === "fHandoff") { commitText(P, "#fHandoff", "handoff"); doneMd(P, "fHandoff"); }
      if (id === "fBlocked") { commitText(P, "#fBlocked", "blockedBy", oneLine); if (P.pendingBlock) { P.pendingBlock = false; if (P.id) refreshSheet(P); } }
      if (id === "gBody") saveGuide();
    });
    sh.addEventListener("keydown", e => {
      const t = e.target;
      if ((t.id === "fTitle" || t.id === "fBlocked") && e.key === "Enter") { e.preventDefault(); t.blur(); }
      if (t.id === "fUbWhy" && !e.isComposing && (e.key === "Enter" || e.key === "Escape")) { e.preventDefault(); e.stopPropagation(); if (e.key === "Enter") unblock(P); else { P.ub = null; refreshSheet(P); } return; }
      // In a Markdown editor, Escape or Cmd/Ctrl+Enter finishes editing instead of closing the panel.
      if (t.classList.contains("md-ta") && (e.key === "Escape" || (e.key === "Enter" && (e.metaKey || e.ctrlKey)))) { e.preventDefault(); e.stopPropagation(); t.blur(); }
      if (t.classList.contains("md-view") && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); editMd(P, t.dataset.for); }
      // Escape leaves the description as it was instead of closing the panel.
      if (t.classList.contains("lk-in") && (e.key === "Escape" || (e.key === "Enter" && !e.isComposing))) { e.preventDefault(); e.stopPropagation(); endLinkEdit(P, t, e.key === "Enter"); return; }
      if (e.key !== "Enter" || e.isComposing) return;
      if (t.id === "fAddSub") {
        const v = t.value.trim(); if (!v) return; e.preventDefault();
        addStep(P.id, { title: v });
        t.value = "";
      }
      if (t.id === "fAddLink") {
        e.preventDefault(); if (!t.value.trim()) return;
        if (addLinks(P, t.value)) t.value = ""; else toast("That doesn't look like a link. Paste a full URL.");
      }
    });
  }
  window.addEventListener("pagehide", () => { flushText(PM); flushText(PS); saveGuide(); });
  document.addEventListener("visibilitychange", () => { if (document.hidden) { flushText(PM); flushText(PS); } });

  // ---------- boot ----------
  render();
  (async () => {
    let db = null;
    try { db = window.claude && typeof window.claude.use === "function" ? await window.claude.use("db") : null; } catch (e) { db = null; }
    if (!db) { S.offline = true; render(); return; }
    S.db = db;
    const fail = err => { if (err && err.code === "revoked") { S.offline = true; S.db = null; } else toast("Lost the live connection. Reload the page to reconnect."); render(); };
    db.collection("items").onSnapshot(snap => {
      const m = new Map(); snap.docs.forEach(d => m.set(d.id, Object.assign({}, d.data(), { id: d.id })));
      S.items = m; S.gotItems = true; render();
    }, fail);
    db.collection("steps").onSnapshot(snap => {
      const m = new Map(); snap.docs.forEach(d => m.set(d.id, Object.assign({}, d.data(), { id: d.id })));
      S.steps = m; render();
    }, fail);
    db.collection("meta").onSnapshot(snap => {
      const d = snap.docs.find(x => x.id === "agent-guide");
      S.guideExists = !!d; S.guide = d ? d.data() : null; refreshGuide();
    }, fail);
    db.collection("journal").onSnapshot(snap => {
      const m = new Map(); snap.docs.forEach(d => m.set(d.id, Object.assign({}, d.data(), { id: d.id })));
      S.journal = m; render();
    }, fail);
    db.collection("projects").onSnapshot(snap => {
      const m = new Map(); snap.docs.forEach(d => m.set(d.id, Object.assign({}, d.data(), { id: d.id })));
      S.projects = m; S.gotProjects = true; render();
    }, fail);
    db.collection("history").onSnapshot(snap => {
      const m = new Map(); snap.docs.forEach(d => m.set(d.id, Object.assign({}, d.data(), { id: d.id })));
      S.history = m; render();
      if (!S.pruned && !S.readOnly) { S.pruned = true; prune(); }
    }, fail);
  })();
})();
