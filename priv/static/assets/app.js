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
})();
