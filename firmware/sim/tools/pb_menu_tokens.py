"""Count a pb.menu frame's JSON tokens exactly as the firmware's cable_json_guard.c does (limit 512), and write
boundary menus for the sim: `pb_menu_tokens.py FILE` prints FILE's count; `--boundary DIR` writes 512/513-token menus."""
import json, sys

def tokens(text):
    n, string, escaped, atom = 0, False, False, False
    for c in text:
        if string:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': string = False
            continue
        if c in ' \t\n\r': atom = False; continue
        if c == '"': n += 1; string = True; atom = False
        elif c in '{[': n += 1; atom = False
        elif c in '}]:,': atom = False
        elif not atom: n += 1; atom = True
    return n

def menu(rows):
    return json.dumps({"t": "pb.menu", "title": "Settings", "items": rows}, separators=(',', ':'), ensure_ascii=False)

def boundary(total):
    """A menu of exactly `total` tokens: picture choices (7) while plenty is left, then plain ones (3), then unknown
    "k":"v" keys (2, which the firmware ignores); a full row (16) starts a new one (11 more)."""
    rows = []
    def size(): return tokens(menu(rows))
    def row():
        if not rows or len(rows[-1]["choices"]) == 16:
            rows.append({"id": f"r{len(rows)}", "label": f"Row {len(rows)}", "value": "A", "index": 0, "choices": []})
        return rows[-1]
    while total - size() >= 30: row()["choices"].append({"value": "Choice", "pet": "claude", "builtin": True})
    while total - size() >= 5: row()["choices"].append({"value": "x"})
    r = total - size()
    if r == 3: row()["choices"].append({"value": "x"})
    elif r == 4: rows[0]["k1"] = "v"; rows[0]["k2"] = "v"
    elif r == 2: rows[0]["k1"] = "v"
    assert size() == total, (size(), total)
    return menu(rows)

if __name__ == '__main__':
    if sys.argv[1] == '--boundary':
        for total in (512, 513):
            text = boundary(total)
            open(f"{sys.argv[2]}/menu_{total}.json", "w").write(text)
            print(total, tokens(text), len(text.encode()), "bytes")
    else:
        print(tokens(open(sys.argv[1]).read()))
