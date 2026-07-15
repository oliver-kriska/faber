// No-build LiveView client: phoenix.min.js and phoenix_live_view.min.js are loaded first as UMD
// globals (`Phoenix`, `LiveView`), then this script wires up the LiveSocket. Kept as a static
// file (not inline) so the layout template stays free of JS braces.
(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var csrfToken = meta ? meta.getAttribute("content") : null;
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
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

  document.addEventListener("click", function (e) {
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
})();
