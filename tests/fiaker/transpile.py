# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import re, sys, pathlib

def strip_outside_strings(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        # long bracket string / comment
        if src.startswith("[[", i):
            j = src.find("]]", i+2); j = n if j < 0 else j+2
            out.append(src[i:j]); i = j; continue
        if src.startswith("--", i):
            j = src.find("\n", i); j = n if j < 0 else j
            out.append(src[i:j]); i = j; continue
        if c in "\"'":
            j = i+1
            while j < n:
                if src[j] == "\\": j += 2; continue
                if src[j] == c: j += 1; break
                j += 1
            out.append(src[i:j]); i = j; continue
        out.append(c); i += 1
    return "".join(out)

TYPE = r"\{[^{}]*\}|\([^()]*\)|[A-Za-z_][\w.]*"

def convert(src):
    # protect strings/comments by processing segment-wise
    segs, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("[[", i):
            j = src.find("]]", i+2); j = n if j < 0 else j+2
            segs.append((src[i:j], False)); i = j; continue
        if src.startswith("--", i):
            j = src.find("\n", i); j = n if j < 0 else j
            segs.append((src[i:j], False)); i = j; continue
        if c in "\"'":
            j = i+1
            while j < n:
                if src[j] == "\\": j += 2; continue
                if src[j] == c: j += 1; break
                j += 1
            segs.append((src[i:j], False)); i = j; continue
        j = i
        while j < n and src[j] not in "\"'" and not src.startswith("--", j) and not src.startswith("[[", j):
            j += 1
        segs.append((src[i:j], True)); i = j
    out = []
    for text, code in segs:
        if code:
            text = re.sub(r"::\s*(?:%s)(\?)?" % TYPE, "", text)      # casts
            for _ in range(4):
                text = re.sub(r":\s*(?:%s)(\?)?" % TYPE, "", text)   # annotations
            text = re.sub(r"(\b[\w.\[\]]+)\s*\+=\s*", r"\1 = \1 + ", text)
            text = re.sub(r"(\b[\w.\[\]]+)\s*-=\s*", r"\1 = \1 - ", text)
        out.append(text)
    return "".join(out)

# Each input is written to ./lib/<name>.luau relative to the cwd.
for p in sys.argv[1:]:
    src = pathlib.Path(p).read_text().replace("--!nonstrict", "")
    dst = pathlib.Path("lib") / pathlib.Path(p).name
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(convert(src).replace('require("./', 'require("').replace('.luau")', '")'))
    print("->", dst)
