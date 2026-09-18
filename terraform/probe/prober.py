#!/usr/bin/env python3
"""
Latency prober for the Azure <-> AWS Multicloud Interconnect lab.

Runs from two vantage points and reports into the same collector:

  * "azure-hub-eastus"     - an Azure Container Instances group injected into
                             the hub VNet, next to the ExpressRoute gateway.
  * "azure-spoke-eastus2"  - a systemd unit on the Linux VM in the spoke VNet.

The point of running both is the delta. The hub vantage measures the
interconnect; the spoke vantage measures the interconnect *plus* the eastus2 ->
eastus hop that the forced region split imposes.

Standard library only. The ACI image is mcr.microsoft.com/azurelinux/base/python
(Docker Hub is not reachable from ACI in this subscription) and the VM has
whatever python3 Ubuntu ships, so nothing may be pip-installed.
"""

import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

VANTAGE = os.environ.get("PROBE_VANTAGE", "unknown")
REGION = os.environ.get("PROBE_REGION", "unknown")
COLLECTOR = os.environ.get("PROBE_COLLECTOR_URL", "").rstrip("/")
INTERVAL = float(os.environ.get("PROBE_INTERVAL_SECONDS", "5"))
TIMEOUT = float(os.environ.get("PROBE_TIMEOUT_SECONDS", "2"))
TCP_PORT = int(os.environ.get("PROBE_TCP_PORT", "22"))
TARGET = os.environ.get("PROBE_TARGET", "")
TARGET_LABEL = os.environ.get("PROBE_TARGET_LABEL", TARGET)

# A freshly created container group has no dataplane routes for a few seconds.
# The first probe reliably fails with EHOSTUNREACH and the one after it can take
# over a second. Both are artifacts of route programming, not path latency, so
# they are measured, logged, and thrown away.
WARMUP_SAMPLES = int(os.environ.get("PROBE_WARMUP_SAMPLES", "3"))

BATCH_MAX = 60
_ident = os.getpid() & 0xFFFF


def log(msg):
    print("[%s] %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg), flush=True)


def checksum(data):
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) + data[i + 1]
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def icmp_available():
    """Probe for CAP_NET_RAW once, at startup, so the UI can be honest."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        s.close()
        return True
    except Exception as exc:
        log("ICMP unavailable (%s: %s) - reporting TCP only" % (type(exc).__name__, exc))
        return False


def icmp_ping(host, seq):
    """One ICMP echo. Returns RTT in ms, or None on timeout/error.

    Payload is deliberately tiny. ExpressRoute caps the TCP/UDP payload at 1400
    bytes and does not fragment; a latency probe has no reason to go near that.
    """
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        sock.settimeout(TIMEOUT)
        payload = b"mcilab-probe"
        header = struct.pack("!BBHHH", 8, 0, 0, _ident, seq)
        header = struct.pack("!BBHHH", 8, 0, checksum(header + payload), _ident, seq)
        started = time.perf_counter()
        sock.sendto(header + payload, (host, 0))

        while True:
            remaining = TIMEOUT - (time.perf_counter() - started)
            if remaining <= 0:
                return None
            sock.settimeout(remaining)
            data, _ = sock.recvfrom(2048)
            elapsed = (time.perf_counter() - started) * 1000.0
            ihl = (data[0] & 0x0F) * 4
            if len(data) < ihl + 8:
                continue
            typ, _code, _cks, rid, rseq = struct.unpack("!BBHHH", data[ihl:ihl + 8])
            # Echo replies for other processes share this raw socket, so match
            # on our identifier and sequence before trusting the timing.
            if typ == 0 and rid == _ident and rseq == seq:
                return elapsed
    except Exception:
        return None
    finally:
        if sock is not None:
            sock.close()


def tcp_rtt(host, port):
    """Time a full TCP handshake. Works everywhere, including where ICMP does not."""
    started = time.perf_counter()
    conn = None
    try:
        conn = socket.create_connection((host, port), timeout=TIMEOUT)
        return (time.perf_counter() - started) * 1000.0
    except Exception:
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def post(batch):
    if not COLLECTOR:
        for sample in batch:
            log(json.dumps(sample))
        return True
    body = json.dumps({"vantage": VANTAGE, "region": REGION, "samples": batch}).encode()
    req = urllib.request.Request(
        COLLECTOR + "/ingest",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        return True
    except Exception as exc:
        log("collector POST failed (%s: %s) - buffering" % (type(exc).__name__, exc))
        return False


def main():
    if not TARGET:
        log("PROBE_TARGET is unset; nothing to measure")
        return 1

    have_icmp = icmp_available()
    log("vantage=%s region=%s target=%s:%d interval=%ss icmp=%s collector=%s"
        % (VANTAGE, REGION, TARGET, TCP_PORT, INTERVAL, have_icmp, COLLECTOR or "stdout"))

    pending = []
    seq = 0
    while True:
        cycle_started = time.perf_counter()
        seq = (seq + 1) & 0xFFFF

        sample = {
            "ts": time.time(),
            "target": TARGET,
            "target_label": TARGET_LABEL,
            "tcp_port": TCP_PORT,
            "tcp_ms": tcp_rtt(TARGET, TCP_PORT),
            "icmp_ms": icmp_ping(TARGET, seq) if have_icmp else None,
            "icmp_supported": have_icmp,
        }

        if seq <= WARMUP_SAMPLES:
            log("warmup %d/%d discarded (tcp=%s icmp=%s)"
                % (seq, WARMUP_SAMPLES, sample["tcp_ms"], sample["icmp_ms"]))
        else:
            pending.append(sample)

        if pending:
            # Keep the buffer bounded; if the collector is down for a long time
            # the freshest samples matter more than a perfect history.
            if len(pending) > BATCH_MAX * 4:
                pending = pending[-BATCH_MAX * 4:]
            if post(pending[:BATCH_MAX]):
                pending = pending[BATCH_MAX:]

        drift = INTERVAL - (time.perf_counter() - cycle_started)
        if drift > 0:
            time.sleep(drift)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
