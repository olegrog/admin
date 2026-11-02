#!/usr/bin/env python3
"""Prepare tunnel-only Skoltech DNS using a locally installed vpnc-script.

No root access, credential access, or system changes. Output is created exclusively.
"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path)
parser.add_argument('--output', type=Path, default=Path('vpnc-script-skoltech'))
args = parser.parse_args()
candidates = [args.source] if args.source else [Path('/opt/homebrew/etc/vpnc/vpnc-script'), Path('/usr/local/etc/vpnc/vpnc-script')]
source = next((p for p in candidates if p and p.is_file()), None)
if source is None:
    parser.error('No installed vpnc-script found; supply --source /path/to/vpnc-script.')
text = source.read_text()
if '# Tunnel-only DNS for a Skoltech' in text:
    parser.error('Source is already patched; no output written.')
for name, commands in (
    ('modify_resolvconf_generic', '''open
d.init
d.add ServerAddresses * $INTERNAL_IP4_DNS
d.add DomainName skoltech.ru
d.add SearchDomains * skoltech.ru
d.add SupplementalMatchDomains * skoltech.ru
set State:/Network/Service/$TUNDEV/DNS
close'''),
    ('restore_resolvconf_generic', '''open
remove State:/Network/Service/$TUNDEV/DNS
close'''),
):
    marker = name + '() {\n'
    if text.count(marker) != 1:
        parser.error('Unsupported vpnc-script layout; no output written.')
    body = '\t# Tunnel-only DNS for a Skoltech macOS split connection.\n'
    body += '\tif [ "$OS" = Darwin ] && [ "$CISCO_DEF_DOMAIN" = skoltech.ru ] && [ "${CISCO_SPLIT_INC:-0}" -gt 0 ]; then\n'
    body += '\t\tscutil <<-EOF\n' + ''.join('\t\t\t' + line + '\n' for line in commands.splitlines())
    body += '\t\tEOF\n\t\treturn $?\n\tfi\n'
    text = text.replace(marker, marker + body)
with args.output.open('x') as output:
    output.write(text)
args.output.chmod(0o755)
print('Created', args.output, 'from', source)
print('Review and install the generated hook as described in README.md.')
