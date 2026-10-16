#!/usr/bin/env python3
"""生成 Grafana 看板 JSON。

改看板时请改这个文件，再运行：
    python3 tools/gen_dashboard.py
默认输出到 server/grafana/dashboards/claude-usage.json，Grafana 大约 10 秒内自动加载。
"""
import json
import sys
from pathlib import Path

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "server/grafana/dashboards/claude-usage.json"

DS = {"type": "loki", "uid": "loki"}
BASE = '{service_name="claude-code", token=~"$token", user_name=~"$user"}'
SEL = BASE + ' | event_name="api_request"'
ERR = BASE + ' | event_name="api_error"'

def unwrap(field, by=None, rng="$__range"):
    agg = f"sum by ({by})" if by else "sum"
    return f'{agg} (sum_over_time({SEL} | unwrap {field} | __error__="" [{rng}]))'

def count(by=None, rng="$__range"):
    agg = f"sum by ({by})" if by else "sum"
    return f"{agg} (count_over_time({SEL} [{rng}]))"

def total_tokens(by=None, rng="$__range"):
    return " + ".join(unwrap(f, by, rng) for f in ["input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"])

def tgt(ref, expr, instant=True, legend=None):
    t = {"refId": ref, "expr": expr, "datasource": DS, "queryType": "instant" if instant else "range"}
    if legend: t["legendFormat"] = legend
    return t

panels, y = [], 0

def stat(title, expr, unit, x, w=4, desc=None, decimals=None):
    p = {"type": "stat", "title": title, "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": 4},
         "targets": [tgt("A", expr)],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": "none", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
         "fieldConfig": {"defaults": {"unit": unit, "noValue": "0"}, "overrides": []}}
    if decimals is not None: p["fieldConfig"]["defaults"]["decimals"] = decimals
    if desc: p["description"] = desc
    panels.append(p)

def table(title, by_labels, cols, h, desc=None, sort_col=None):
    """cols: list of (列名, expr, unit)"""
    refs = [chr(ord("A") + i) for i in range(len(cols))]
    rename = {f"Value #{r}": c[0] for r, c in zip(refs, cols)}
    rename.update(by_labels)
    overrides = [{"matcher": {"id": "byName", "options": c[0]},
                  "properties": [{"id": "unit", "value": c[2]}]}
                 for c in cols]
    p = {"type": "table", "title": title, "datasource": DS, "gridPos": {"x": 0, "y": y, "w": 24, "h": h},
         "targets": [tgt(r, c[1]) for r, c in zip(refs, cols)],
         "transformations": [
             {"id": "merge", "options": {}},
             {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": rename,
                                            "indexByName": {**{k: i for i, k in enumerate(by_labels)},
                                                            **{f"Value #{r}": len(by_labels) + i for i, r in enumerate(refs)}}}},
         ],
         "options": {"showHeader": True, "cellHeight": "sm",
                     "sortBy": [{"displayName": sort_col or cols[-1][0], "desc": True}],
                     "footer": {"show": True, "reducer": ["sum"], "fields": [c[0] for c in cols], "countRows": False}},
         "fieldConfig": {"defaults": {"unit": "short", "noValue": "0", "custom": {"align": "auto"}}, "overrides": overrides}}
    if desc: p["description"] = desc
    panels.append(p)

def timeseries(title, expr, legend, unit, x, w=12, h=8, bars=True):
    panels.append({"type": "timeseries", "title": title, "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": h},
                   "targets": [tgt("A", expr, instant=False, legend=legend)],
                   "fieldConfig": {"defaults": {"unit": unit, "custom": {
                       "drawStyle": "bars" if bars else "line", "fillOpacity": 80 if bars else 10, "lineWidth": 1,
                       "stacking": {"mode": "normal", "group": "A"}, "barAlignment": 0}}, "overrides": []},
                   "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["sum"]},
                               "tooltip": {"mode": "multi", "sort": "desc"}}})

def row(title):
    global y
    panels.append({"type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

COST_DESC = "按 API 标价折算的等价费用，订阅不按这个扣费，仅用于比较各账号/各人的用量大小。"

# ---------- 总览 ----------
row("总览（所选时间范围）")
stat("请求数", count(), "short", 0, w=3)
stat("总 Token", total_tokens(), "short", 3, desc="input + output + 缓存读 + 缓存写")
stat("输出 Token", unwrap("output_tokens"), "short", 7)
stat("等价 API 费用", unwrap("cost_usd"), "currencyUSD", 11, desc=COST_DESC, decimals=2)
stat("失败请求", f"sum(count_over_time({ERR} [$__range]))", "short", 15, w=3, desc="429 通常表示该 token 的订阅额度用完了；401 表示 token 失效")
stat("活跃 Token", f"count({count('token')})", "short", 18, w=3)
stat("活跃人数", f"count({count('user_name')})", "short", 21, w=3)
y += 4

# ---------- 按订阅账号 ----------
row("按 Token")
table("各 Token 用量（所选时间范围）", {"token": "Token", "token_fp": "指纹"}, [
    ("请求数", count("token, token_fp"), "short"),
    ("失败请求", f"sum by (token, token_fp) (count_over_time({ERR} [$__range]))", "short"),
    ("输入", unwrap("input_tokens", "token, token_fp"), "short"),
    ("输出", unwrap("output_tokens", "token, token_fp"), "short"),
    ("缓存读", unwrap("cache_read_tokens", "token, token_fp"), "short"),
    ("缓存写", unwrap("cache_creation_tokens", "token, token_fp"), "short"),
    ("总 Token", total_tokens("token, token_fp"), "short"),
    ("等价费用", unwrap("cost_usd", "token, token_fp"), "currencyUSD"),
], h=8, desc="Token 列显示登记的别名，没登记的显示指纹（服务器上 ./register-token.sh 登记）。" + COST_DESC)
y += 8
table("额度窗口参考（按 Token，截至所选时间范围的终点，不受时间范围影响）", {"token": "Token"}, [
    ("近 5 小时请求", count("token", "5h"), "short"),
    ("近 5 小时 Token", total_tokens("token", "5h"), "short"),
    ("近 5 小时等价费用", unwrap("cost_usd", "token", "5h"), "currencyUSD"),
    ("近 7 天 Token", total_tokens("token", "7d"), "short"),
    ("近 7 天等价费用", unwrap("cost_usd", "token", "7d"), "currencyUSD"),
], h=7, sort_col="近 5 小时等价费用",
   desc="订阅额度按账号的 5 小时窗口和周窗口计算，官方不公开具体额度。同一个账号生成的多个 token 共用额度，需要把它们加起来，再和 claude.ai 设置 → 用量里的百分比对照。")
y += 7
table("失败请求明细（所选时间范围）", {"token": "Token", "status_code": "状态码", "error": "错误信息"}, [
    ("次数", f"sum by (token, status_code, error) (count_over_time({ERR} [$__range]))", "short"),
], h=6, desc="429 = 额度或频率限制；401 = token 失效或被撤销；5xx = Anthropic 服务端错误")
y += 6
timeseries("Token 趋势（按 Token）", total_tokens("token", "$__auto"), "{{token}}", "short", 0)
timeseries("等价费用趋势（按 Token）", unwrap("cost_usd", "token", "$__auto"), "{{token}}", "currencyUSD", 12)
y += 8

# ---------- 按使用人 ----------
row("按使用人 / 机器")
table("各使用人用量（所选时间范围）", {"user_name": "使用人", "host_name": "机器", "token": "Token"}, [
    ("请求数", count("user_name, host_name, token"), "short"),
    ("输出", unwrap("output_tokens", "user_name, host_name, token"), "short"),
    ("总 Token", total_tokens("user_name, host_name, token"), "short"),
    ("等价费用", unwrap("cost_usd", "user_name, host_name, token"), "currencyUSD"),
], h=9)
y += 9
timeseries("请求数趋势（按使用人）", count("user_name", "$__auto"), "{{user_name}}", "short", 0)
timeseries("等价费用趋势（按使用人）", unwrap("cost_usd", "user_name", "$__auto"), "{{user_name}}", "currencyUSD", 12)
y += 8

# ---------- 按模型 ----------
row("按模型")
table("各模型用量（所选时间范围）", {"model": "模型"}, [
    ("请求数", count("model"), "short"),
    ("输入", unwrap("input_tokens", "model"), "short"),
    ("输出", unwrap("output_tokens", "model"), "short"),
    ("总 Token", total_tokens("model"), "short"),
    ("等价费用", unwrap("cost_usd", "model"), "currencyUSD"),
], h=7)
y += 7

def var(name, label, lbl):
    return {"name": name, "label": label, "type": "query", "datasource": DS,
            "query": {"type": 1, "label": lbl, "stream": '{service_name="claude-code"}', "refId": "LokiVariableQueryEditor-VariableQuery"},
            "definition": f'label_values({{service_name="claude-code"}},{lbl})',
            "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*", "sort": 1,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}}

dash = {
    "uid": "claude-usage", "title": "Claude setup-token 用量", "tags": ["claude"], "timezone": "browser",
    "schemaVersion": 39, "version": 1, "editable": True, "graphTooltip": 1,
    "time": {"from": "now-7d", "to": "now"}, "refresh": "1m",
    "timepicker": {"refresh_intervals": ["30s", "1m", "5m", "15m", "1h"]},
    "templating": {"list": [var("token", "Token", "token"), var("user", "使用人", "user_name")]},
    "panels": panels,
}
out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
with open(out, "w") as f:
    json.dump(dash, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"已生成 {out}（{len(panels)} 个面板）")
