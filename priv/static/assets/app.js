// No-build LiveView client: phoenix.min.js and phoenix_live_view.min.js are loaded first as UMD
// globals (`Phoenix`, `LiveView`), then this script wires up the LiveSocket. Kept as a static
// file (not inline) so the layout template stays free of JS braces.
(function () {
  // Theme: default is dark (the CSS :root). A stored choice overrides it via `data-theme` on
  // <html>, which is outside the LiveView root, so LiveView never touches it. Applied as early as
  // this deferred script runs; a light chooser sees at most a brief first-paint flash.
  try {
    var savedTheme = localStorage.getItem("faber-theme");
    if (savedTheme === "light" || savedTheme === "dark") {
      document.documentElement.setAttribute("data-theme", savedTheme);
    }
  } catch (e) {
    /* private mode / storage disabled — stay on the default theme */
  }

  var meta = document.querySelector("meta[name='csrf-token']");
  var csrfToken = meta ? meta.getAttribute("content") : null;

  // Keep the selected master-list row in view during keyboard navigation. The hook is attached
  // only to the currently-selected <li>, so it mounts when a row becomes selected (arrow keys,
  // or the top row after a scan) and scrolls that row into view. `block: "nearest"` avoids
  // jumping the whole page when the row is already visible; the default (instant) scroll needs
  // no reduced-motion handling.
  var Hooks = {
    SelectedIntoView: {
      mounted() { this.el.scrollIntoView({ block: "nearest" }); },
    },

    // Continuous overview⇄detail morph. `data-mode` on `.stage` flips the grid between the full
    // table (`1fr 0fr`) and the table-as-sidebar split (`30fr 70fr`). CSS can't interpolate `fr`
    // tracks — the engine stalls at the start value — so we FLIP it by hand: capture the resolved
    // pixel tracks + gap BEFORE the LiveView patch, read the target AFTER, then rAF-tween between
    // them. Falls back to the instant CSS switch under reduced motion or a stacked narrow layout.
    StageMorph: {
      mounted() {
        this.reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
        this.narrow = window.matchMedia("(max-width: 720px)");
        this.prevMode = this.el.dataset.mode;
      },
      beforeUpdate() {
        var cs = getComputedStyle(this.el);
        this.fromCols = cs.gridTemplateColumns;
        this.fromGap = cs.columnGap;
        this.prevMode = this.el.dataset.mode;
      },
      updated() {
        var mode = this.el.dataset.mode;
        if (mode !== this.prevMode) this.morph();
        this.prevMode = mode;
      },
      destroyed() {
        if (this.raf) cancelAnimationFrame(this.raf);
      },
      morph() {
        var el = this.el;
        // Reduced motion or the narrow stacked layout: let the CSS end-state apply instantly.
        if (this.reduce.matches || this.narrow.matches) return;

        // The patch already applied the target `data-mode`, so the current computed columns ARE
        // the end state. Read them, then animate up from the captured pre-patch values (the invert).
        el.style.gridTemplateColumns = "";
        el.style.columnGap = "";
        var toCols = parseTrack(getComputedStyle(el).gridTemplateColumns);
        var toGap = parseNum(getComputedStyle(el).columnGap);
        var fromCols = parseTrack(this.fromCols);
        var fromGap = parseNum(this.fromGap);
        if (!fromCols || !toCols || fromCols.length !== toCols.length) return;

        if (this.raf) cancelAnimationFrame(this.raf);
        var dur = 360;
        var t0 = performance.now();
        var self = this;
        var frame = function (now) {
          var p = Math.min(1, (now - t0) / dur);
          var e = 1 - Math.pow(1 - p, 3); // ease-out cubic — no overshoot
          var cols = fromCols.map(function (f, i) { return (f + (toCols[i] - f) * e).toFixed(2) + "px"; });
          el.style.gridTemplateColumns = cols.join(" ");
          el.style.columnGap = (fromGap + (toGap - fromGap) * e).toFixed(2) + "px";
          if (p < 1) {
            self.raf = requestAnimationFrame(frame);
          } else {
            self.raf = null;
            el.style.gridTemplateColumns = ""; // hand back to CSS (the `fr` tracks resolve to the same px)
            el.style.columnGap = "";
          }
        };
        this.raf = requestAnimationFrame(frame);
      },
    },
  };

  // Pull the numeric px values out of a computed `grid-template-columns` (e.g. "334px 762px").
  function parseTrack(s) {
    var m = (s || "").match(/-?[\d.]+/g);
    return m ? m.map(Number) : null;
  }
  function parseNum(s) {
    var n = parseFloat(s);
    return isNaN(n) ? 0 : n;
  }

  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks,
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;

  // Copy-to-clipboard for [data-copy="#selector"] buttons, plus click-to-select-all on the
  // rendered skill block. Both are delegated on document so they survive LiveView DOM patches
  // without registering a LiveView hook.
  function flash(btn) {
    var prev = btn.textContent;
    btn.textContent = "Copied ✓";
    btn.classList.add("copied");
    setTimeout(function () {
      btn.textContent = prev;
      btn.classList.remove("copied");
    }, 1200);
  }

  function copyText(text, btn) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { flash(btn); });
      return;
    }
    // Fallback for non-secure contexts: a throwaway textarea + execCommand.
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); flash(btn); } finally { ta.remove(); }
  }

  // Close every open popover (install menu + filter combo) except `keep` (the one opening now).
  // These are client-managed via a `.open` class so they're instant and survive LiveView patches;
  // selecting an item fires a LiveView event whose re-render drops the class and closes the menu.
  function closePopovers(keep) {
    document.querySelectorAll(".install.open, .combo.open").forEach(function (el) {
      if (el !== keep) {
        el.classList.remove("open");
        syncExpanded(el);
      }
    });
  }

  // Keep the trigger's aria-expanded in step with its popover's `.open` state, so a screen reader
  // announces the combo/menu as expanded or collapsed (the class alone is invisible to AT).
  function syncExpanded(el) {
    var trigger = el.querySelector("[data-combo-toggle], [data-install-toggle]");
    if (trigger) {
      trigger.setAttribute("aria-expanded", el.classList.contains("open") ? "true" : "false");
    }
  }

  // Show/hide a combo's options by a case-insensitive substring of their label (the "All" option,
  // which has no data-combo-item, always stays). Toggles the "No matches" line.
  function filterCombo(combo, q) {
    var query = q.trim().toLowerCase();
    var any = false;
    combo.querySelectorAll(".combo-list li[data-combo-item]").forEach(function (li) {
      var hit = query === "" || (li.getAttribute("data-combo-item") || "").indexOf(query) !== -1;
      li.hidden = !hit;
      if (hit) any = true;
    });
    var empty = combo.querySelector(".combo-empty");
    if (empty) empty.hidden = any || query === "";
  }

  document.addEventListener("click", function (e) {
    // Theme toggle: flip light ⇄ dark on <html> and persist. Default (no attr) is dark, so the
    // first toggle goes to light.
    var themeBtn = e.target.closest("[data-theme-toggle]");
    if (themeBtn) {
      var next =
        document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
      document.documentElement.setAttribute("data-theme", next);
      try {
        localStorage.setItem("faber-theme", next);
      } catch (e2) {
        /* storage disabled — the theme still applies for this session */
      }
      return;
    }

    // Filter combo: toggle its `.combo` open/closed; on open, reset + focus the search box.
    var comboToggle = e.target.closest("[data-combo-toggle]");
    if (comboToggle) {
      var combo = comboToggle.closest(".combo");
      var openCombo = combo.classList.contains("open");
      closePopovers(combo);
      combo.classList.toggle("open", !openCombo);
      syncExpanded(combo);
      if (!openCombo) {
        var search = combo.querySelector("[data-combo-search]");
        if (search) {
          search.value = "";
          filterCombo(combo, "");
          setTimeout(function () { search.focus(); }, 0);
        }
      }
      return;
    }

    // Install dropdown: same open/close mechanics.
    var installToggle = e.target.closest("[data-install-toggle]");
    if (installToggle) {
      var wrap = installToggle.closest(".install");
      var openInstall = wrap.classList.contains("open");
      closePopovers(wrap);
      wrap.classList.toggle("open", !openInstall);
      syncExpanded(wrap);
      return;
    }

    // Clicks inside an open combo/install (e.g. picking an option) are left for LiveView, whose
    // re-render closes the menu. Any other click closes all open popovers.
    if (!e.target.closest(".combo") && !e.target.closest(".install")) {
      closePopovers(null);
    }

    var btn = e.target.closest("[data-copy]");
    if (btn) {
      var target = document.querySelector(btn.getAttribute("data-copy"));
      if (target) copyText(target.innerText, btn);
      return;
    }
    // Click the skill code block to select it all (quick manual copy).
    var skill = e.target.closest("pre.skill");
    if (skill && window.getSelection) {
      var range = document.createRange();
      range.selectNodeContents(skill);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
  });

  // Type-to-filter inside a searchable combo.
  document.addEventListener("input", function (e) {
    var search = e.target.closest("[data-combo-search]");
    if (search) filterCombo(search.closest(".combo"), search.value);
  });

  document.addEventListener("keydown", function (e) {
    // Escape closes any open popover (keyboard parity with click-away).
    if (e.key === "Escape") { closePopovers(null); return; }

    // Typing in a field must never reach the LiveView window-level nav. The `.stage` binds
    // `phx-window-keydown="nav"` (arrows / j / k move the selection), which listens on `window`;
    // stopping the event at `document` keeps it from bubbling up to that handler while the user is
    // typing into the project filter search — otherwise every keystroke also moved the ranking.
    if (e.target.closest("input, textarea, select, [contenteditable]")) {
      e.stopPropagation();
      return;
    }

    // A focused ranked row is operated like a button: Space activates it (Enter is wired
    // server-side via `phx-keydown="select"` on the row). preventDefault stops Space scrolling.
    if (e.key === " " || e.key === "Spacebar") {
      var row = e.target.closest(".srow");
      if (row) { e.preventDefault(); row.click(); }
    }
  });
})();
