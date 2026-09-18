#!/usr/bin/env python3
"""
Collector + web dashboard for the interconnect latency probe.

Lives on the spoke VM because nothing else can host it. In this subscription:

  * VMs cannot be created in eastus at all (every SKU is restricted at
    type: Location).
  * Container Apps cannot be created in eastus either - the environment build
    fails with AKSCapacityHeavyUsage, because ACA is AKS-backed and inherits the
    same capacity wall.
  * App Service has a quota of 0 VMs in eastus for every SKU tried.
  * VNet-injected Container Instances *do* work in eastus, but a container group
    in a VNet gets a private IP only and cannot expose ingress.

So the prober runs in eastus (ACI, in the hub, next to the ExpressRoute
gateway) and ships its samples here, to the one place in the lab that already
has a public IP with an NSG locked to the operator's address.

Standard library only - the VM installs no packages for this.
"""

import json
import os
import statistics
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("COLLECTOR_PORT", "8080"))
DATA_DIR = os.environ.get("COLLECTOR_DATA_DIR", "/var/lib/mcilab-probe")
DATA_FILE = os.path.join(DATA_DIR, "samples.jsonl")
RETENTION_DAYS = float(os.environ.get("COLLECTOR_RETENTION_DAYS", "7"))
RETENTION_SECONDS = RETENTION_DAYS * 86400

# The dashboard may be exposed publicly so it can be shared, but ingest must not
# be: POST /ingest is unauthenticated, so anyone who could reach it could poison
# the measurements or fill the disk. GET traffic is read-only and harmless.
#
# Both probers sit inside the VNet, so restricting ingest to private space costs
# nothing and removes the entire class of problem.
INGEST_CIDRS = [
    c.strip()
    for c in os.environ.get("COLLECTOR_INGEST_CIDRS", "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8").split(",")
    if c.strip()
]

# Labels for the topology diagram. Passed in by Terraform so the page never
# carries its own copy of a CIDR or a region name.
TOPOLOGY = {
    "hub_region": os.environ.get("TOPO_HUB_REGION", "azure hub"),
    "hub_cidr": os.environ.get("TOPO_HUB_CIDR", ""),
    "spoke_region": os.environ.get("TOPO_SPOKE_REGION", "azure spoke"),
    "spoke_cidr": os.environ.get("TOPO_SPOKE_CIDR", ""),
    "probe_cidr": os.environ.get("TOPO_PROBE_CIDR", ""),
    "aws_region": os.environ.get("TOPO_AWS_REGION", "aws"),
    "aws_cidr": os.environ.get("TOPO_AWS_CIDR", ""),
    "aws_target": os.environ.get("TOPO_AWS_TARGET", ""),
    "hub_vantage": os.environ.get("TOPO_HUB_VANTAGE", ""),
    "spoke_vantage": os.environ.get("TOPO_SPOKE_VANTAGE", ""),
}


def ip_to_int(addr):
    try:
        parts = [int(p) for p in addr.split(".")]
    except ValueError:
        return None
    if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
        return None
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]


def in_cidr(addr, cidr):
    if "/" not in cidr:
        return addr == cidr
    net, bits = cidr.split("/", 1)
    addr_i, net_i = ip_to_int(addr), ip_to_int(net)
    if addr_i is None or net_i is None:
        return False
    try:
        bits = int(bits)
    except ValueError:
        return False
    if bits <= 0:
        return True
    mask = ((1 << bits) - 1) << (32 - bits)
    return (addr_i & mask) == (net_i & mask)


def parse_window(raw, default=3600.0):
    """Accept '900', '15m', '6h', '7d'. Never raise - a bad window is a bad
    query string, not a reason to 500 the endpoint."""
    if raw is None:
        return default
    raw = str(raw).strip().lower()
    if not raw:
        return default
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    scale = 1
    if raw[-1] in units:
        scale = units[raw[-1]]
        raw = raw[:-1]
    try:
        return float(raw) * scale
    except ValueError:
        return default

_lock = threading.Lock()
_samples = []
_last_compaction = 0.0


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    idx = int(round((pct / 100.0) * (len(ordered) - 1)))
    return ordered[max(0, min(idx, len(ordered) - 1))]


def load():
    global _samples
    if not os.path.exists(DATA_FILE):
        return
    cutoff = time.time() - RETENTION_SECONDS
    loaded = []
    with open(DATA_FILE, "r") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("ts", 0) >= cutoff:
                loaded.append(row)
    _samples = loaded
    print("loaded %d samples from %s" % (len(_samples), DATA_FILE), flush=True)


def compact_locked():
    """Rewrite the file without expired rows. Called sparingly; it is O(n)."""
    global _last_compaction
    cutoff = time.time() - RETENTION_SECONDS
    kept = [s for s in _samples if s.get("ts", 0) >= cutoff]
    _samples[:] = kept
    tmp = DATA_FILE + ".tmp"
    with open(tmp, "w") as handle:
        for row in kept:
            handle.write(json.dumps(row) + "\n")
    os.replace(tmp, DATA_FILE)
    _last_compaction = time.time()
    print("compacted to %d samples" % len(kept), flush=True)


def ingest(payload):
    vantage = payload.get("vantage", "unknown")
    region = payload.get("region", "unknown")
    rows = []
    for sample in payload.get("samples", []):
        sample["vantage"] = vantage
        sample["region"] = region
        rows.append(sample)
    if not rows:
        return 0
    with _lock:
        _samples.extend(rows)
        with open(DATA_FILE, "a") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
        if time.time() - _last_compaction > 3600:
            compact_locked()
    return len(rows)


def window_samples(seconds):
    cutoff = time.time() - seconds
    with _lock:
        return [s for s in _samples if s.get("ts", 0) >= cutoff]


def summarise(seconds):
    rows = window_samples(seconds)
    by_vantage = {}
    for row in rows:
        by_vantage.setdefault(row.get("vantage", "unknown"), []).append(row)

    out = {}
    for vantage, items in by_vantage.items():
        entry = {
            "region": items[-1].get("region", "unknown"),
            "samples": len(items),
            "target": items[-1].get("target"),
            "target_label": items[-1].get("target_label"),
            "tcp_port": items[-1].get("tcp_port"),
            "icmp_supported": bool(items[-1].get("icmp_supported")),
            "last_seen": max(i.get("ts", 0) for i in items),
        }
        for metric in ("tcp_ms", "icmp_ms"):
            values = [i[metric] for i in items if i.get(metric) is not None]
            attempted = len([i for i in items if metric != "icmp_ms" or i.get("icmp_supported")])
            entry[metric] = {
                "count": len(values),
                "loss_pct": (100.0 * (attempted - len(values)) / attempted) if attempted else None,
                "min": min(values) if values else None,
                "p50": percentile(values, 50),
                "p95": percentile(values, 95),
                "p99": percentile(values, 99),
                "max": max(values) if values else None,
                "mean": statistics.fmean(values) if values else None,
            }
        out[vantage] = entry
    return out


def series(seconds, buckets=180):
    rows = window_samples(seconds)
    if not rows:
        return {"buckets": [], "vantages": {}}
    now = time.time()
    start = now - seconds
    width = max(1.0, seconds / float(buckets))

    grouped = {}
    for row in rows:
        vantage = row.get("vantage", "unknown")
        idx = int((row.get("ts", now) - start) / width)
        idx = max(0, min(idx, buckets - 1))
        slot = grouped.setdefault(vantage, {}).setdefault(idx, {"tcp": [], "icmp": []})
        if row.get("tcp_ms") is not None:
            slot["tcp"].append(row["tcp_ms"])
        if row.get("icmp_ms") is not None:
            slot["icmp"].append(row["icmp_ms"])

    out = {"buckets": [start + (i + 0.5) * width for i in range(buckets)], "vantages": {}}
    for vantage, slots in grouped.items():
        tcp = [None] * buckets
        icmp = [None] * buckets
        for idx, slot in slots.items():
            if slot["tcp"]:
                tcp[idx] = percentile(slot["tcp"], 50)
            if slot["icmp"]:
                icmp[idx] = percentile(slot["icmp"], 50)
        out["vantages"][vantage] = {"tcp_ms": tcp, "icmp_ms": icmp}
    return out


PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Azure &rarr; AWS interconnect latency</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--line:#30363d;--fg:#e6edf3;--dim:#8b949e;
--hub:#58a6ff;--spoke:#f0883e;--good:#3fb950;--warn:#d29922}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
header{padding:20px 24px;border-bottom:1px solid var(--line)}
h1{margin:0;font-size:17px;font-weight:600}
.sub{color:var(--dim);font-size:12px;margin-top:4px}
main{padding:24px;max-width:1200px;margin:0 auto}
.delta{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--hub);
padding:16px 20px;border-radius:6px;margin-bottom:24px}
.delta .big{font-size:26px;font-weight:600;color:var(--hub)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:16px;margin-bottom:24px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px 18px}
.card h2{margin:0 0 2px;font-size:14px;display:flex;align-items:center;gap:8px}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block}
.meta{color:var(--dim);font-size:11px;margin-bottom:12px}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{text-align:right;padding:4px 6px;border-bottom:1px solid var(--line)}
th:first-child,td:first-child{text-align:left;color:var(--dim)}
thead th{color:var(--dim);font-weight:500}
.chart{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px 18px;margin-bottom:16px}
.chart h2{margin:0 0 12px;font-size:14px}
.legend{display:flex;gap:18px;font-size:12px;color:var(--dim);margin-bottom:8px;flex-wrap:wrap}
.controls{display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap}
button{background:var(--panel);color:var(--fg);border:1px solid var(--line);
border-radius:5px;padding:5px 12px;cursor:pointer;font:inherit;font-size:12px}
button.on{border-color:var(--hub);color:var(--hub)}
.note{color:var(--dim);font-size:11px;margin-top:10px}
.badge{font-size:10px;padding:1px 6px;border-radius:9px;border:1px solid var(--line);color:var(--dim)}
.badge.ok{color:var(--good);border-color:var(--good)}
.badge.no{color:var(--warn);border-color:var(--warn)}
</style></head><body>
<header>
  <h1>Azure &rarr; AWS private latency over Multicloud Interconnect</h1>
  <div class="sub">Two vantage points into the same AWS us-east-1 target. The gap between them is the cost of the forced eastus/eastus2 region split.</div>
</header>
<main>
  <div class="controls">
    <button data-w="900">15m</button><button data-w="3600" class="on">1h</button>
    <button data-w="21600">6h</button><button data-w="86400">24h</button>
    <button data-w="604800">7d</button>
    <button id="metric" style="margin-left:auto">metric: TCP</button>
  </div>
  <div id="delta" class="delta"></div>
  <div class="chart">
    <h2>Measured path</h2>
    <div class="note" style="margin:0 0 10px">Both probes hit the same AWS target. The hub probe sits beside the ExpressRoute gateway; the spoke probe reaches it across a VNet peering first, and that extra leg is the whole difference.</div>
    <svg id="topo" viewBox="0 0 1000 250" style="width:100%;height:250px"></svg>
  </div>
  <div id="cards" class="grid"></div>
  <div class="chart">
    <h2>Median RTT over time</h2>
    <div class="legend" id="legend"></div>
    <svg id="chart" viewBox="0 0 1000 300" preserveAspectRatio="none" style="width:100%;height:300px"></svg>
    <div class="note">Each point is the median of the samples in its bucket. Gaps mean no successful probe in that bucket.</div>
  </div>
</main>
<script>
var TOPO=__TOPOLOGY__;
var WINDOW=3600, METRIC="tcp_ms";
var COLORS={}, PALETTE=["#58a6ff","#f0883e","#3fb950","#d29922"];
function ms(v){return v==null?"&mdash;":v.toFixed(2)+" ms";}
function colorFor(n){if(!(n in COLORS)){COLORS[n]=PALETTE[Object.keys(COLORS).length%PALETTE.length];}return COLORS[n];}

function renderCards(sum){
  var names=Object.keys(sum).sort();
  var cards=document.getElementById("cards"); cards.innerHTML="";
  names.forEach(function(n){
    var e=sum[n], m=e[METRIC]||{}, icmpOk=e.icmp_supported;
    var age=Math.round(Date.now()/1000-(e.last_seen||0));
    cards.insertAdjacentHTML("beforeend",
      '<div class="card"><h2><span class="dot" style="background:'+colorFor(n)+'"></span>'+n+
      ' <span class="badge '+(icmpOk?"ok":"no")+'">ICMP '+(icmpOk?"ok":"unavailable")+'</span></h2>'+
      '<div class="meta">'+e.region+' &rarr; '+(e.target_label||e.target||"?")+':'+(e.tcp_port||"?")+
      ' &middot; '+e.samples+' samples &middot; last seen '+age+'s ago</div>'+
      '<table><thead><tr><th>metric</th><th>min</th><th>p50</th><th>p95</th><th>p99</th><th>max</th><th>loss</th></tr></thead><tbody>'+
      ["tcp_ms","icmp_ms"].map(function(k){
        var s=e[k]||{};
        return '<tr><td>'+(k==="tcp_ms"?"TCP":"ICMP")+'</td><td>'+ms(s.min)+'</td><td>'+ms(s.p50)+
        '</td><td>'+ms(s.p95)+'</td><td>'+ms(s.p99)+'</td><td>'+ms(s.max)+'</td><td>'+
        (s.loss_pct==null?"&mdash;":s.loss_pct.toFixed(1)+"%")+'</td></tr>';
      }).join("")+'</tbody></table></div>');
  });
}

function renderDelta(sum){
  var names=Object.keys(sum).sort(), el=document.getElementById("delta");
  var hub=names.filter(function(n){return n.indexOf("hub")>=0;})[0];
  var spoke=names.filter(function(n){return n.indexOf("spoke")>=0;})[0];
  if(!hub||!spoke||!sum[hub][METRIC]||!sum[spoke][METRIC]||
     sum[hub][METRIC].p50==null||sum[spoke][METRIC].p50==null){
    el.innerHTML='<div class="sub">Waiting for samples from both vantage points&hellip;</div>';return;
  }
  var h=sum[hub][METRIC].p50, s=sum[spoke][METRIC].p50, d=s-h;
  var pct=s>0?(100*d/s):0;
  el.innerHTML='<div>Region-split cost at p50 ('+(METRIC==="tcp_ms"?"TCP":"ICMP")+')</div>'+
    '<div class="big">+'+d.toFixed(2)+' ms</div>'+
    '<div class="sub">hub '+h.toFixed(2)+' ms vs spoke '+s.toFixed(2)+' ms &mdash; '+
    pct.toFixed(0)+'% of the spoke measurement is the eastus2&rarr;eastus hop, not the interconnect.</div>';
}

function renderChart(ser){
  var svg=document.getElementById("chart"), W=1000,H=300,P=38;
  var names=Object.keys(ser.vantages).sort();
  var all=[];
  names.forEach(function(n){ser.vantages[n][METRIC].forEach(function(v){if(v!=null)all.push(v);});});
  if(!all.length){svg.innerHTML='<text x="20" y="30" fill="#8b949e" font-size="13">No data in this window</text>';
    document.getElementById("legend").innerHTML="";return;}
  var lo=0, hi=Math.max.apply(null,all)*1.15;
  var n=ser.buckets.length;
  var x=function(i){return P+(W-P-10)*(i/(n-1||1));};
  var y=function(v){return H-P-(H-P-14)*((v-lo)/(hi-lo||1));};
  var out="";
  for(var g=0;g<=4;g++){
    var gv=lo+(hi-lo)*g/4, gy=y(gv);
    out+='<line x1="'+P+'" y1="'+gy+'" x2="'+(W-10)+'" y2="'+gy+'" stroke="#30363d" stroke-width="1"/>'+
         '<text x="'+(P-6)+'" y="'+(gy+4)+'" fill="#8b949e" font-size="11" text-anchor="end">'+gv.toFixed(1)+'</text>';
  }
  names.forEach(function(nm){
    var d=ser.vantages[nm][METRIC], seg=[], path="";
    for(var i=0;i<d.length;i++){
      if(d[i]==null){if(seg.length>1)path+=seg.join(" ")+" ";seg=[];continue;}
      seg.push((seg.length?"L":"M")+x(i).toFixed(1)+","+y(d[i]).toFixed(1));
    }
    if(seg.length>1)path+=seg.join(" ");
    if(path)out+='<path d="'+path+'" fill="none" stroke="'+colorFor(nm)+'" stroke-width="1.8"/>';
  });
  var t0=new Date(ser.buckets[0]*1000), t1=new Date(ser.buckets[n-1]*1000);
  out+='<text x="'+P+'" y="'+(H-12)+'" fill="#8b949e" font-size="11">'+t0.toLocaleTimeString()+'</text>'+
       '<text x="'+(W-10)+'" y="'+(H-12)+'" fill="#8b949e" font-size="11" text-anchor="end">'+t1.toLocaleTimeString()+'</text>';
  svg.innerHTML=out;
  document.getElementById("legend").innerHTML=names.map(function(nm){
    return '<span><span class="dot" style="background:'+colorFor(nm)+'"></span> '+nm+'</span>';}).join("")+
    '<span style="margin-left:auto">y axis: milliseconds</span>';
}

function topoPick(s,key,hint){
  if(TOPO[key] && s[TOPO[key]]) return TOPO[key];
  var names=Object.keys(s);
  for(var i=0;i<names.length;i++){ if(names[i].indexOf(hint)>=0) return names[i]; }
  return null;
}

function renderTopo(s){
  var svg=document.getElementById("topo"); if(!svg) return;
  var HUB="#58a6ff", SPOKE="#f0883e", WIRE="#8b949e", LINK="#3fb950";
  var hubName=topoPick(s,"hub_vantage","hub"), spokeName=topoPick(s,"spoke_vantage","spoke");

  function rtt(nm){
    if(!nm||!s[nm]||!s[nm][METRIC]||s[nm][METRIC].p50==null) return "awaiting data";
    return "p50 "+s[nm][METRIC].p50.toFixed(2)+" ms";
  }
  function esc(t){return String(t==null?"":t).replace(/&/g,"&amp;").replace(/</g,"&lt;");}
  function box(x,y,w,h,color,lines){
    var o='<rect x="'+x+'" y="'+y+'" width="'+w+'" height="'+h+'" rx="6" fill="#0e1116" stroke="'+color+'" stroke-width="1.4"/>';
    for(var i=0;i<lines.length;i++){
      var l=lines[i];
      o+='<text x="'+(x+w/2)+'" y="'+(y+18+i*15)+'" text-anchor="middle" fill="'+(l.c||"#e6edf3")+
         '" font-size="'+(l.s||11)+'" font-weight="'+(l.b?600:400)+'">'+esc(l.t)+'</text>';
    }
    return o;
  }
  function arrow(x1,y1,x2,y2,color,dash){
    return '<path d="M'+x1+','+y1+' L'+x2+','+y2+'" stroke="'+color+'" stroke-width="1.6" fill="none"'+
           (dash?' stroke-dasharray="4 3"':'')+' marker-end="url(#ah-'+color.replace("#","")+')"/>';
  }
  function label(x,y,t,color,anchor){
    return '<text x="'+x+'" y="'+y+'" text-anchor="'+(anchor||"middle")+'" fill="'+color+'" font-size="10">'+esc(t)+'</text>';
  }

  var defs='<defs>';
  [HUB,SPOKE,WIRE,LINK].forEach(function(c){
    defs+='<marker id="ah-'+c.replace("#","")+'" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">'+
          '<path d="M0,0 L10,5 L0,10 z" fill="'+c+'"/></marker>';
  });
  defs+='</defs>';

  var o=defs;

  // Two Azure vantage points on the left, the shared path across the middle.
  o+=box(14,26,196,58,HUB,[
    {t:"ACI prober",b:1,c:HUB},
    {t:esc(TOPO.hub_region)+(TOPO.probe_cidr?" \u00b7 "+TOPO.probe_cidr:""),s:10,c:"#8b949e"},
    {t:rtt(hubName),s:11,c:HUB}]);
  o+=box(14,148,196,58,SPOKE,[
    {t:"VM prober + collector",b:1,c:SPOKE},
    {t:esc(TOPO.spoke_region)+(TOPO.spoke_cidr?" \u00b7 "+TOPO.spoke_cidr:""),s:10,c:"#8b949e"},
    {t:rtt(spokeName),s:11,c:SPOKE}]);

  o+=box(268,87,124,58,WIRE,[
    {t:"ExpressRoute",b:1},{t:"gateway",b:1},
    {t:TOPO.hub_cidr?"hub "+TOPO.hub_cidr:"hub",s:9,c:"#8b949e"}]);
  o+=box(430,87,132,58,LINK,[
    {t:"Azure Multicloud",b:1,c:LINK},{t:"Interconnect circuit",s:10,c:LINK}]);
  o+=box(600,87,132,58,LINK,[
    {t:"AWS Interconnect",b:1,c:LINK},{t:"multicloud",s:10,c:LINK}]);
  o+=box(770,87,108,58,WIRE,[
    {t:"DX gateway",b:1},{t:"\u2192 VGW",s:10,c:"#8b949e"}]);
  o+=box(902,87,84,58,"#ED7100",[
    {t:"EC2",b:1,c:"#ED7100"},
    {t:esc(TOPO.aws_region),s:9,c:"#8b949e"},
    {t:esc(TOPO.aws_target),s:9,c:"#8b949e"}]);

  // Lane A goes straight to the gateway. Lane B pays for a peering first.
  o+=arrow(210,55,264,100,HUB,false);
  o+=label(238,44,"same region",HUB);
  o+=arrow(210,177,264,133,SPOKE,false);
  o+=label(232,196,"VNet peering",SPOKE);
  o+=label(232,208,"(extra hop)",SPOKE);

  o+=arrow(392,116,426,116,WIRE,false);
  o+=arrow(562,116,596,116,LINK,false);
  o+=arrow(732,116,766,116,LINK,false);
  o+=arrow(878,116,898,116,WIRE,false);

  o+=label(500,78,"no BGP, VLAN or peering config \u2014 the providers own the underlay","#8b949e");

  // The collector lives on the spoke VM, so the hub samples travel back over
  // the same peering. That is reporting traffic, not measured traffic.
  o+='<path d="M112,84 L112,120 L112,148" stroke="'+HUB+'" stroke-width="1.2" stroke-dasharray="3 3" fill="none" marker-end="url(#ah-'+HUB.replace("#","")+')"/>';
  o+=label(120,120,"samples \u2192 collector",HUB,"start");

  var d=null;
  if(hubName&&spokeName&&s[hubName][METRIC].p50!=null&&s[spokeName][METRIC].p50!=null)
    d=s[spokeName][METRIC].p50-s[hubName][METRIC].p50;
  o+=label(500,236,d==null?"region-split cost: awaiting data":
    "region-split cost at p50: "+d.toFixed(2)+" ms of the spoke figure is the eastus2 detour, not the interconnect",
    d==null?"#8b949e":"#d29922");

  svg.innerHTML=o;
}

function refresh(){
  fetch("api/summary?window="+WINDOW).then(function(r){return r.json();}).then(function(s){
    Object.keys(s).sort().forEach(colorFor); renderDelta(s); renderCards(s); renderTopo(s);});
  fetch("api/series?window="+WINDOW).then(function(r){return r.json();}).then(renderChart);
}
document.querySelectorAll("button[data-w]").forEach(function(b){
  b.onclick=function(){document.querySelectorAll("button[data-w]").forEach(function(o){o.classList.remove("on");});
    b.classList.add("on");WINDOW=+b.dataset.w;refresh();};});
document.getElementById("metric").onclick=function(){
  METRIC=METRIC==="tcp_ms"?"icmp_ms":"tcp_ms";
  this.textContent="metric: "+(METRIC==="tcp_ms"?"TCP":"ICMP");refresh();};
refresh(); setInterval(refresh,10000);
</script></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # the probe writes one line every few seconds; access logs are noise

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        window = parse_window(query.get("window", [None])[0])
        window = max(60.0, min(window, RETENTION_SECONDS))

        if parsed.path in ("/", "/index.html"):
            self._send(200, PAGE.replace("__TOPOLOGY__", json.dumps(TOPOLOGY)), "text/html; charset=utf-8")
        elif parsed.path == "/healthz":
            with _lock:
                count = len(_samples)
            self._send(200, json.dumps({"status": "ok", "samples": count}))
        elif parsed.path == "/api/summary":
            self._send(200, json.dumps(summarise(window)))
        elif parsed.path == "/api/series":
            self._send(200, json.dumps(series(window)))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if urlparse(self.path).path != "/ingest":
            self._send(404, json.dumps({"error": "not found"}))
            return

        # The dashboard is shareable; the write path is not.
        peer = self.client_address[0]
        if not any(in_cidr(peer, c) for c in INGEST_CIDRS):
            self._send(403, json.dumps({"error": "ingest is restricted to the lab network"}))
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception as exc:
            self._send(400, json.dumps({"error": str(exc)}))
            return
        self._send(200, json.dumps({"accepted": ingest(payload)}))


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    load()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("collector listening on :%d (retention %.1f days)" % (PORT, RETENTION_DAYS), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
