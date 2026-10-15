"""極簡 VCD 解析器：讀出每個訊號的 (時間, 值) 變化列表。"""


def parse_vcd(path):
    id2names = {}          # VCD 識別碼 -> [完整階層名稱...]
    scope = []
    changes = {}           # 完整名稱 -> [(time_ps, value_str)]
    t = 0
    in_defs = True
    with open(path) as f:
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if in_defs:
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    vid, name = tok[3], tok[4]
                    full = ".".join(scope + [name])
                    id2names.setdefault(vid, []).append(full)
                    changes[full] = []
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            c = tok[0]
            if c[0] == "#":
                t = int(c[1:])
            elif c[0] in "bB":
                val, vid = c[1:], tok[1]
                for n in id2names.get(vid, []):
                    changes[n].append((t, val))
            elif c[0] in "01xXzZ":
                val, vid = c[0], c[1:]
                for n in id2names.get(vid, []):
                    changes[n].append((t, val))
    return changes


def value_at(chg, t):
    """訊號在時間 t（ps）的值。"""
    v = "x"
    for tt, vv in chg:
        if tt > t:
            break
        v = vv
    return v


def to_int(v):
    try:
        return int(v, 2)
    except ValueError:
        return None
