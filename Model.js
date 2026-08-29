// Input classification and result parsing for the Karakeep quick-add widget.
// Qt-free so it can be unit tested under node (tests/karakeep-test.sh).

// Karakeep's managed cloud. The OpenAPI spec's own default, try.karakeep.app,
// is the shared public demo instance, not a personal server.
var DEFAULT_SERVER_URL = "https://cloud.karakeep.app"

// A phrase that merely mentions a URL is a note, not a link. Transport
// enforcement (HTTPS origins) lives in the helper, not here.
function looksLikeUrl(value) {
  return /^https?:\/\/[^\s]+$/i.test(String(value == null ? "" : value).trim())
}

function bookmarkPayload(content) {
  var text = String(content == null ? "" : content).trim()
  if (text === "") return null
  return looksLikeUrl(text) ? { type: "link", url: text } : { type: "text", text: text }
}

function previewUrl(serverUrl, id) {
  var base = String(serverUrl == null ? "" : serverUrl).replace(/\/+$/, "")
  var key = String(id == null ? "" : id)
  return base === "" || key === ""
    ? ""
    : base + "/dashboard/preview/" + encodeURIComponent(key)
}

// Only a complete address gets a link — a half-typed host would send the user
// to a dead tab.
function apiKeysUrl(serverUrl) {
  var base = String(serverUrl == null ? "" : serverUrl).trim().replace(/\/+$/, "")
  return looksLikeUrl(base) ? base + "/settings/api-keys" : ""
}

// Every field is coerced to its own type, so unreadable or hostile helper
// output can only reach the panel as a failure and nothing outside this fixed
// set is carried through.
function parseResult(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return {
      ok: parsed.ok === true,
      error: String(parsed.error || ""),
      configured: parsed.configured === true,
      serverUrl: String(parsed.serverUrl || ""),
      id: String(parsed.id || ""),
      existing: parsed.existing === true
    }
  } catch (error) {
    return {
      ok: false,
      error: "Karakeep returned an unreadable response.",
      configured: false,
      serverUrl: "",
      id: "",
      existing: false
    }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_SERVER_URL: DEFAULT_SERVER_URL,
    looksLikeUrl: looksLikeUrl,
    bookmarkPayload: bookmarkPayload,
    previewUrl: previewUrl,
    apiKeysUrl: apiKeysUrl,
    parseResult: parseResult
  }
}
