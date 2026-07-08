# Developer Tools — Sill

Post-PoC. Scope for the next build pass, informed by real usage.

**Standing rule:** capabilities arrive quietly. Never a mode, a badge, or a visual costume change. (Arc's Developer Mode is the counter-example: full UI/colour change per tab, auto-installed extension on a localhost heuristic. Nothing below gets a mode, an outline, or an auto-install step.)

## 1. Inspector
Standard WKWebView/Safari inspector. `isInspectable = true`, always on, no trigger, reachable via right-click and a menu item. No custom DevTools build.

## 2. Page capture
Core toolbar feature, not developer-gated. Full-page and partial/visible-area capture, both always available. Same snapshot mechanism as the MCP `capture_page` tool; two entry points, one capability.

## 3. API client (lite)
First-party request builder: method, URL, headers, body, response viewer, history, named environments. Shipped with more than originally scoped here: OpenAPI/Swagger/Postman collection import (`APIClientStore.importCollection`), auto-detected from live docs pages. No scripting, no team features.

## 4. JSON formatting
Always-on rendering: any JSON-content-type or JSON-parseable response body renders as a collapsible, highlighted tree. Applied on direct navigation and inside the API client's response viewer. No extension, no toggle.

## 5. MCP explorer
The API client's sibling, for people building with or for the Model Context Protocol: connect to a server (a local stdio command run through a login shell, or a remote streamable-HTTP endpoint), browse everything it exposes — tools, resources, prompts — and invoke any of it, with argument forms generated from each tool's own JSON schema and a live server-log pane (stdio stderr + logging notifications). Same internal-tab machinery as the API client (`sill://mcp-client`), same sidebar/detail structure, same JSON tree for results. Distinct from the roadmap's H6 "MCP layer", which is Sill acting as an MCP *server* for external agents; this is Sill as an MCP *client*.
