#!/usr/bin/env python3
"""EasyList Cookie List (ABP syntax) -> Safari content-blocker JSON.

Conservative by design: anything that doesn't map cleanly onto WebKit's
content-blocker model is skipped and counted, never guessed at. The output
is verified by actually compiling it with WKContentRuleListStore afterwards
(all-or-nothing compile, so a single bad rule is caught).

Rule order in output: css-display-none hides, then network blocks, then
ignore-previous-rules exceptions (must come last to cancel earlier rules).

Refreshing the bundled list:
    curl -sL https://secure.fanboy.co.nz/fanboy-cookiemonster.txt -o /tmp/cookielist.txt
    python3 scripts/convert-cookie-list.py /tmp/cookielist.txt \
        Sources/Sill/Resources/Blocklists/easylist-cookie.json
then verify the output still compiles before shipping — WebKit's compile is
all-or-nothing, so one bad rule silently kills the whole list at runtime
(ContentBlocker.swift only NSLogs the failure).
"""
import json
import re
import sys
from collections import OrderedDict

SRC = sys.argv[1] if len(sys.argv) > 1 else "fanboy-cookiemonster.txt"
DST = sys.argv[2] if len(sys.argv) > 2 else "easylist-cookie.json"

# Selector constructs WebKit's content-blocker CSS engine may reject or
# that carry ABP/uBO extended semantics.
BAD_SELECTOR = re.compile(
    r":has\(|:has-text|:-abp-|:xpath\(|:matches-css|:style\(|:remove\(|\[-ext-|::content|:contains\(|:watch-attr|:min-text-length"
)
ASCII = re.compile(r"^[\x00-\x7F]*$")

SUPPORTED_TYPES = {
    "script": "script", "image": "image", "stylesheet": "style-sheet",
    "xmlhttprequest": "raw", "media": "media", "font": "font",
    "popup": "popup", "subdocument": "document", "document": "document",
}
# Options that mark the whole-page whitelist flavour of an @@ exception.
DOC_WHITELIST_OPTS = {"document", "elemhide", "generichide", "genericblock"}

stats = {"hide": 0, "hide_skipped": 0, "hide_exc_applied": 0, "hide_exc_dropped": 0,
         "net": 0, "net_skipped": 0, "exc": 0, "exc_skipped": 0, "procedural_skipped": 0}


def escape_regex(s):
    return re.sub(r"[.+?${}()|\[\]\\/]", lambda m: "\\" + m.group(0), s)


def pattern_to_url_filter(pattern):
    """ABP URL pattern -> Safari url-filter regex, or None if unmappable."""
    if not ASCII.match(pattern):
        return None
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2:
        return None  # raw ABP regex rule: don't trust dialect compatibility
    anchor_start = anchor_end = False
    host_anchor = False
    if pattern.startswith("||"):
        host_anchor = True
        pattern = pattern[2:]
    elif pattern.startswith("|"):
        anchor_start = True
        pattern = pattern[1:]
    if pattern.endswith("|"):
        anchor_end = True
        pattern = pattern[:-1]
    out = []
    for ch in pattern:
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            out.append("[^a-zA-Z0-9_.%-]")
        else:
            out.append(escape_regex(ch))
    body = "".join(out)
    if host_anchor:
        # Same shape as the existing easylist-adservers.json rules.
        body = "^[^:]+://+([^:/]+\\.)?" + body
    elif anchor_start:
        body = "^" + body
    if anchor_end:
        body += "$"
    return body


def domain_lists(domain_str, sep):
    """Split an ABP domain option into (positives, negatives), *-prefixed."""
    pos, neg = [], []
    for d in filter(None, domain_str.split(sep)):
        if not ASCII.match(d) or "*" in d:
            return None, None  # wildcard TLD domains unsupported
        if d.startswith("~"):
            neg.append("*" + d[1:].lower())
        else:
            pos.append("*" + d.lower())
    return pos, neg


# --- pass 1: element hiding ---------------------------------------------
# generic[selector] = set(unless-domains); sited[selector] = set(if-domains)
generic = OrderedDict()
sited = OrderedDict()
net_rules = []
exception_rules = []

for raw in open(SRC, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("!") or line.startswith("["):
        continue
    if "#?#" in line or "#$#" in line or "#%#" in line:
        stats["procedural_skipped"] += 1
        continue

    if "#@#" in line:  # hide exception, applied in pass 2
        continue

    if "##" in line:
        domains_part, selector = line.split("##", 1)
        selector = selector.strip()
        if not selector or BAD_SELECTOR.search(selector) or not ASCII.match(selector):
            stats["hide_skipped"] += 1
            continue
        pos, neg = domain_lists(domains_part, ",")
        if pos is None:
            stats["hide_skipped"] += 1
            continue
        if pos:
            sited.setdefault(selector, set()).update(pos)
        else:
            generic.setdefault(selector, set()).update(neg)
        stats["hide"] += 1
        continue

    # --- network rule ---
    is_exception = line.startswith("@@")
    if is_exception:
        line = line[2:]
    pattern, _, opts_str = line.partition("$")
    opts = [o for o in opts_str.split(",") if o] if opts_str else []

    trigger = {}
    resource_types = []
    load_types = []
    unsupported = False
    doc_whitelist = False
    for opt in opts:
        name, _, val = opt.partition("=")
        if name == "third-party":
            load_types.append("third-party")
        elif name == "~third-party":
            load_types.append("first-party")
        elif name == "domain":
            pos, neg = domain_lists(val, "|")
            if pos is None or (pos and neg):
                unsupported = True
                break
            if pos:
                trigger["if-domain"] = sorted(pos)
            elif neg:
                trigger["unless-domain"] = sorted(neg)
        elif name in SUPPORTED_TYPES:
            resource_types.append(SUPPORTED_TYPES[name])
        elif name in DOC_WHITELIST_OPTS and is_exception:
            doc_whitelist = True
        else:
            unsupported = True  # csp=, redirect=, ~script, important, ...
            break
    if unsupported:
        stats["exc_skipped" if is_exception else "net_skipped"] += 1
        continue

    url_filter = pattern_to_url_filter(pattern)
    if url_filter is None:
        stats["exc_skipped" if is_exception else "net_skipped"] += 1
        continue
    trigger["url-filter"] = url_filter
    if resource_types:
        trigger["resource-type"] = sorted(set(resource_types))
    if doc_whitelist:
        trigger["resource-type"] = ["document"]
    if load_types:
        trigger["load-type"] = sorted(set(load_types))

    rule = {"trigger": trigger,
            "action": {"type": "ignore-previous-rules" if is_exception else "block"}}
    (exception_rules if is_exception else net_rules).append(rule)
    stats["exc" if is_exception else "net"] += 1

# --- pass 2: hide exceptions --------------------------------------------
for raw in open(SRC, encoding="utf-8"):
    line = raw.strip()
    if "#@#" not in line or line.startswith("!"):
        continue
    domains_part, selector = line.split("#@#", 1)
    selector = selector.strip()
    pos, _neg = domain_lists(domains_part, ",")
    if not pos:
        stats["hide_exc_dropped"] += 1
        continue
    applied = False
    if selector in generic:
        generic[selector].update(pos)
        applied = True
    if selector in sited:
        sited[selector] -= set(pos)
        if not sited[selector]:
            del sited[selector]
        applied = True
    stats["hide_exc_applied" if applied else "hide_exc_dropped"] += 1

# --- emit ----------------------------------------------------------------
rules = []

# Generic hides, grouped by identical unless-domain set, selectors chunked.
by_unless = OrderedDict()
for selector, unless in generic.items():
    by_unless.setdefault(tuple(sorted(unless)), []).append(selector)
CHUNK = 200
for unless, selectors in by_unless.items():
    for i in range(0, len(selectors), CHUNK):
        trigger = {"url-filter": ".*"}
        if unless:
            trigger["unless-domain"] = list(unless)
        rules.append({"trigger": trigger,
                      "action": {"type": "css-display-none",
                                 "selector": ", ".join(selectors[i:i + CHUNK])}})

# Site-specific hides, grouped by identical if-domain set.
by_if = OrderedDict()
for selector, doms in sited.items():
    by_if.setdefault(tuple(sorted(doms)), []).append(selector)
for doms, selectors in by_if.items():
    for i in range(0, len(selectors), CHUNK):
        rules.append({"trigger": {"url-filter": ".*", "if-domain": list(doms)},
                      "action": {"type": "css-display-none",
                                 "selector": ", ".join(selectors[i:i + CHUNK])}})

rules.extend(net_rules)
rules.extend(exception_rules)

with open(DST, "w", encoding="utf-8") as f:
    json.dump(rules, f, separators=(",", ":"))

print(f"rules emitted: {len(rules)}")
for k, v in stats.items():
    print(f"  {k}: {v}")
