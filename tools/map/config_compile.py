"""配置表编译器：config/*.xlsx（##var / ##type / ## 三行表头）→ game/data/generated/*.json

用法：
  双击 config/同步配置表.bat
  或 python tools/map/config_compile.py [--check]

校验：类型、枚举、必填、数值范围、id 唯一、外键（ref）、自定义 checks。
任何一条不过 → 不写文件，旧数据保持不动。
"""
import json
import shutil
import sys
from pathlib import Path

from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config"
OUT = ROOT / "game" / "data" / "generated"

VAR_ROW = "##var"
TYPE_ROW = "##type"
DOC_ROW = "##"


def read_table(path, sheet=None):
    """返回 (headers, types, rows)。headers 来自 ##var 行，rows 是 dict 列表。"""
    wb = load_workbook(path, read_only=True, data_only=True)
    ws = wb[sheet] if sheet else wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        raise ValueError("表格是空的")

    def norm(v):
        return "" if v is None else (v.strip() if isinstance(v, str) else v)

    head = [norm(c) for c in rows[0]]
    if not head or str(head[0]).strip() != VAR_ROW:
        raise ValueError("第一行 A1 必须是 ##var（当前 = %r）" % (rows[0][0] if rows else None))
    # A 列是行指令列，真正的字段名从 B 列开始
    headers = [str(c).strip() for c in head[1:]]
    types = [""] * len(headers) if len(rows) < 2 else [norm(c) for c in rows[1][1:]]
    data_start = 2
    if len(rows) > 2 and str(norm(rows[2][0])).startswith("##"):
        data_start = 3

    out = []
    for n, r in enumerate(rows[data_start:], start=data_start + 1):
        if not r or all(norm(v) == "" for v in r):
            continue
        rec = {}
        for i, h in enumerate(headers):
            if not h or h.startswith("#"):
                continue
            ri = i + 1                      # +1：跳过 A 列指令列
            rec[h] = norm(r[ri]) if ri < len(r) else ""
        rec["_row"] = n
        out.append(rec)
    wb.close()
    return headers, types, out


def coerce(value, ftype, spec, where, errors):
    """把单元格转成目标类型，失败时记错误返回 None。"""
    if value == "" or value is None:
        if spec.get("required"):
            errors.append("%s：必填为空" % where)
        return None
    if ftype == "string":
        return str(value)
    if ftype == "int":
        try:
            return int(float(value))
        except (TypeError, ValueError):
            errors.append("%s：'%s' 不是整数" % (where, value))
            return None
    if ftype == "float":
        try:
            v = float(value)
        except (TypeError, ValueError):
            errors.append("%s：'%s' 不是数字" % (where, value))
            return None
        if "min" in spec and v < spec["min"] or "max" in spec and v > spec["max"]:
            errors.append("%s：%s 超出范围 [%s, %s]" % (where, v, spec.get("min"), spec.get("max")))
            return None
        return v
    if ftype == "enum":
        v = str(value).strip()
        if v not in spec["values"]:
            errors.append("%s：'%s' 不在枚举 %s 里" % (where, v, "/".join(spec["values"])))
            return None
        return v
    if ftype == "ref":
        return str(value).strip()
    return str(value)


def compile_table(name, tspec, errors, warns):
    path = CONFIG / tspec["file"]
    if not path.exists():
        errors.append("%s：找不到 %s" % (name, tspec["file"]))
        return None
    try:
        headers, types, rows = read_table(path, tspec.get("sheet"))
    except PermissionError:
        errors.append("%s：文件被 Excel 占用，请先保存并关闭" % tspec["file"])
        return None
    except ValueError as e:
        errors.append("%s：%s" % (tspec["file"], e))
        return None

    fields = tspec["fields"]
    # 表头与 schema 对齐检查
    for col in fields:
        if col not in headers:
            errors.append("%s：缺少列 %s" % (tspec["file"], col))
    for col in headers:
        if col and not col.startswith("#") and col not in fields:
            warns.append("%s：多出未定义列 %s（已忽略）" % (tspec["file"], col))

    out = []
    for rec in rows:
        row_no = rec["_row"]
        item = {}
        for col, spec in fields.items():
            where = "%s 第%d行 %s" % (tspec["file"], row_no, col)
            item[col] = coerce(rec.get(col, ""), spec["type"], spec, where, errors)
        item["_row"] = row_no
        out.append(item)

    # 唯一键
    key = tspec.get("key")
    if key:
        seen = {}
        for it in out:
            k = it.get(key)
            if k in seen:
                errors.append("%s 第%d行：%s 重复（与第%d行）" % (tspec["file"], it["_row"], key, seen[k]))
            else:
                seen[k] = it["_row"]

    for chk in tspec.get("checks", []):
        if chk["kind"] == "unique_pair":
            buckets = {}
            for it in out:
                if it.get(chk["field"]) == chk["value"]:
                    g = it.get(chk["group_by"])
                    buckets.setdefault(g, []).append(it["_row"])
            for g, rws in buckets.items():
                if len(rws) > 1:
                    errors.append("%s：%s（%s 有 %d 个，第 %s 行）"
                                  % (tspec["file"], chk["message"], g, len(rws), ", ".join(map(str, rws))))
    return out


def main():
    check_only = "--check" in sys.argv
    schema = json.loads((CONFIG / "schema.json").read_text(encoding="utf-8"))
    tables = schema["tables"]
    errors, warns = [], []
    compiled = {}
    for name, tspec in tables.items():
        rows = compile_table(name, tspec, errors, warns)
        if rows is not None:
            compiled[name] = rows

    # 外键校验（所有表读完之后）
    for name, tspec in tables.items():
        if name not in compiled:
            continue
        for col, spec in tspec["fields"].items():
            if spec["type"] != "ref":
                continue
            target = spec["table"] if "table" in spec else spec.get("target")
            if target not in compiled:
                warns.append("%s.%s：引用表 %s 未定义，跳过校验" % (name, col, target))
                continue
            ids = {str(r.get(tables[target]["key"])) for r in compiled[target]}
            for it in compiled[name]:
                v = it.get(col)
                if v and v not in ids:
                    errors.append("%s 第%d行 %s：'%s' 在 %s 表里不存在"
                                  % (tspec["file"], it["_row"], col, v, target))

    if errors:
        print("发现 %d 个问题，未写入：" % len(errors))
        for e in errors[:40]:
            print("  -", e)
        return 1
    for w in warns[:20]:
        print("  提示:", w)

    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in compiled.items():
        tspec = tables[name]
        clean = [{k: v for k, v in r.items() if k != "_row"} for r in rows]
        dst = OUT / tspec["output"]
        if dst.exists():
            shutil.copyfile(dst, dst.with_suffix(".bak.json"))
        payload = {"_comment": "由 config_compile.py 从 config/%s 生成" % tspec["file"],
                   "version": 1, tspec.get("json_key", name): clean}
        dst.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        kinds = {}
        for r in clean:
            t = r.get("type", "")
            kinds[t] = kinds.get(t, 0) + 1
        extra = "" if not kinds else "  " + "，".join("%s %d" % (k, v) for k, v in sorted(kinds.items()))
        print("已写出 %s：%d 条%s" % (dst.name, len(clean), extra))
    print("切回游戏、打开地图即可生效。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
