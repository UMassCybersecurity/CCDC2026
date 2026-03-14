#!/usr/bin/env python3
"""
CCDC Network Diagram Generator
Reads a CSV inventory and produces a draw.io diagram, grouped by subnet.

Usage:
    python3 ccdc_diagram.py inventory.csv [output.drawio]
    python3 ccdc_diagram.py inventory.csv --no-services --no-domain

USE THIS AS A TEMPLATE TO FURTHER MODIFY IN DRAW.IO. DO NOT SUBMIT AS-IS, CANNOT CONVEY IMPORTANT INFO SUCH AS BEING BEHIND A FIREWALL.
"""

import csv
import sys
import math
import argparse
from pathlib import Path
from xml.etree import ElementTree as ET
from xml.dom import minidom

# ── Column aliases (case-insensitive, exact match preferred over substring) ───
COLUMN_MAP = {
    'name':     ['name'],
    'subnet':   ['subnet'],
    'ipv4':     ['ipv4', 'client (ipv4)'],
    'ipv6':     ['ipv6', 'client (ipv6)'],
    'hostname': ['hostname'],
    'domain':   ['domain'],
    'os':       ['os (version)', 'os'],
    'services': ['scored services', 'running services', 'services', 'open ports'],
}

# ── Layout ────────────────────────────────────────────────────────────────────
NODE_W, NODE_H = 180, 100
COLS           = 3
H_GAP, V_GAP   = 20, 20
PAD            = 30
TITLE_H        = 30
GROUP_GAP      = 50
CANVAS_X       = 60
CANVAS_Y       = 80

# ── Styles ────────────────────────────────────────────────────────────────────
STYLES = {
    'firewall':       'rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;fontStyle=1;',
    'windows_server': 'rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;fontStyle=1;',
    'windows':        'rounded=1;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;',
    'linux':          'rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;',
    'unknown':        'rounded=1;whiteSpace=wrap;html=1;fillColor=#f5f5f5;strokeColor=#666666;',
}
CONTAINER_STYLE = 'swimlane;startSize=30;fillColor=#f9f9f9;strokeColor=#888888;fontSize=12;fontStyle=1;'


# ── Helpers ───────────────────────────────────────────────────────────────────

def _esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def detect_type(name, os_str):
    n, o = name.lower(), os_str.lower()
    if any(k in n for k in ('pfsense', 'firewall', 'fortigate', 'gateway')):
        return 'firewall'
    if 'windows server' in o or 'server 20' in o:
        return 'windows_server'
    if 'windows' in o or 'windows' in n:
        return 'windows'
    if any(k in o for k in ('linux', 'ubuntu', 'debian', 'rocky', 'centos',
                             'rhel', 'suse', 'fedora', 'alma', 'kali')):
        return 'linux'
    return 'unknown'


def find_columns(headers):
    """Map field roles to column indices. Exact match preferred, substring as fallback."""
    h_lower = [h.lower().strip() for h in headers]
    result = {}
    for role, aliases in COLUMN_MAP.items():
        for alias in aliases:
            if alias in h_lower:
                result[role] = h_lower.index(alias)
                break
            for i, h in enumerate(h_lower):
                if alias in h:
                    result[role] = i
                    break
            if role in result:
                break
    return result


def get(row, col_map, role):
    idx = col_map.get(role)
    if idx is None or idx >= len(row):
        return ''
    return (row[idx] or '').strip()


# ── CSV parsing ───────────────────────────────────────────────────────────────

def parse_csv(path):
    for enc in ('utf-8-sig', 'utf-8', 'latin-1'):
        try:
            text = Path(path).read_text(encoding=enc)
            break
        except (UnicodeDecodeError, ValueError):
            continue
    else:
        print(f'[ERROR] Could not decode {path}', file=sys.stderr)
        sys.exit(1)

    rows = list(csv.reader(text.splitlines()))
    if not rows:
        return []

    col_map = find_columns(rows[0])
    if 'name' not in col_map:
        print('[WARN] No "Name" column found — check headers.', file=sys.stderr)

    devices = []
    for row in rows[1:]:
        if not any(c.strip() for c in row):
            continue
        name = get(row, col_map, 'name')
        if not name or name.lower() == 'name':
            continue
        devices.append({role: get(row, col_map, role) for role in COLUMN_MAP})

    return devices


# ── Label builder ─────────────────────────────────────────────────────────────

def make_label(dev, show_services, show_domain):
    parts = [f'<b>{_esc(dev["name"])}</b>']

    if dev['ipv4']:
        parts.append(_esc(dev['ipv4']))
    if dev['ipv6']:
        parts.append(f'<font color="#888888">{_esc(dev["ipv6"][:36])}</font>')
    if dev['hostname'] and dev['hostname'].lower() != dev['name'].lower():
        parts.append(f'<i>{_esc(dev["hostname"])}</i>')
    if dev['os']:
        os_line = dev['os'].split('\n')[0][:42]
        parts.append(f'<font color="#555555">{_esc(os_line)}</font>')
    if show_domain and dev['domain']:
        parts.append(f'<font color="#0055aa">{_esc(dev["domain"])}</font>')
    if show_services and dev['services']:
        svc = dev['services'].replace('\n', ', ')[:50]
        parts.append(f'<font color="#666666" style="font-size:9px;">{_esc(svc)}</font>')

    return '<br>'.join(parts)


# ── draw.io builder ───────────────────────────────────────────────────────────

def build_drawio(devices, show_services=True, show_domain=True):
    # Group by subnet
    groups = {}
    for dev in devices:
        key = dev['subnet'] or '(Unknown Subnet)'
        groups.setdefault(key, []).append(dev)

    counter = [2]
    def next_id():
        v = str(counter[0]); counter[0] += 1; return v

    root = ET.Element('mxGraphModel',
                      dx='1422', dy='762', grid='1', gridSize='10',
                      guides='1', tooltips='1', connect='1', arrows='1',
                      fold='1', page='1', pageScale='1',
                      pageWidth='1654', pageHeight='1169',
                      math='0', shadow='0')
    xr = ET.SubElement(root, 'root')
    ET.SubElement(xr, 'mxCell', id='0')
    ET.SubElement(xr, 'mxCell', id='1', parent='0')

    cur_x = CANVAS_X
    for subnet, devs in sorted(groups.items()):
        cols = min(len(devs), COLS)
        rows = math.ceil(len(devs) / cols)
        w = PAD * 2 + cols * NODE_W + (cols - 1) * H_GAP
        h = TITLE_H + PAD + rows * NODE_H + (rows - 1) * V_GAP + PAD

        cid = next_id()
        c = ET.SubElement(xr, 'mxCell',
                          id=cid, value=_esc(subnet),
                          style=CONTAINER_STYLE, vertex='1', parent='1')
        ET.SubElement(c, 'mxGeometry',
                      x=str(cur_x), y=str(CANVAS_Y),
                      width=str(w), height=str(h),
                      **{'as': 'geometry'})

        for i, dev in enumerate(devs):
            col_i = i % cols
            row_i = i // cols
            nx = PAD + col_i * (NODE_W + H_GAP)
            ny = TITLE_H + PAD + row_i * (NODE_H + V_GAP)

            style = STYLES.get(detect_type(dev['name'], dev['os']), STYLES['unknown'])
            label = make_label(dev, show_services, show_domain)

            node = ET.SubElement(xr, 'mxCell',
                                 id=next_id(), value=label,
                                 style=style, vertex='1', parent=cid)
            ET.SubElement(node, 'mxGeometry',
                          x=str(nx), y=str(ny),
                          width=str(NODE_W), height=str(NODE_H),
                          **{'as': 'geometry'})

        cur_x += w + GROUP_GAP

    return minidom.parseString(ET.tostring(root, encoding='unicode')).toprettyxml(indent='  ')


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='Generate a draw.io diagram from a CCDC inventory CSV.')
    ap.add_argument('csv_file', help='Path to the inventory CSV')
    ap.add_argument('output', nargs='?', help='Output .drawio file (default: <csv>.drawio)')
    ap.add_argument('--no-services', action='store_true', help='Omit services from node labels')
    ap.add_argument('--no-domain',   action='store_true', help='Omit domain from node labels')
    args = ap.parse_args()

    out = Path(args.output) if args.output else Path(args.csv_file).with_suffix('.drawio')

    print(f'[*] Parsing {args.csv_file}')
    devices = parse_csv(args.csv_file)
    if not devices:
        print('[WARN] No devices found.', file=sys.stderr)
        sys.exit(0)

    print(f'[*] Found {len(devices)} device(s)')
    xml = build_drawio(devices, show_services=not args.no_services, show_domain=not args.no_domain)
    out.write_text(xml, encoding='utf-8')
    print(f'[+] Saved: {out}')


if __name__ == '__main__':
    main()
