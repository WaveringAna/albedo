#!/usr/bin/env python3
"""Index paired real-PTY screenshots; never infer coverage from text-only tests."""
import argparse,hashlib,json,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser();parser.add_argument('--final-binary',default='/tmp/albedo-visual-parity/albedo-final');args=parser.parse_args()
final_binary=pathlib.Path(args.final_binary)
final_sha256=hashlib.sha256(final_binary.read_bytes()).hexdigest() if final_binary.is_file() else None
OUT=pathlib.Path('/tmp/albedo-visual-parity')
ATLAS=OUT/'atlas'
STATES={
 'startup/session picker':['picker','empty-picker','picker-query','picker-no-match','picker-cancel','picker-selection'],
 'chat/transcript':['empty','markdown','tool','queued','chat-slash','chat-multiline','chat-scroll','chat-selection','chat-focus','chat-cancel','chat-error','chat-recovery','chat-toggle-thinking','chat-toggle-tools','chat-toggle-diff'],
 'login':['login','login-steps','login-invalid-name','login-invalid-base','login-invalid-key','login-manual-model','saved-login','login-codex-auth','login-codex-manual','login-codex-error','login-codex-models'],
 'model/provider':['model-list','model-provider-switch','model-manual','model-error','model-empty','model-cancel'],
 'extensions':['extensions-list','extensions-confirm','extensions-empty','extensions-error','extensions-retry'],
 'tree':['tree-list','tree-confirm','tree-empty','tree-error','tree-page','tree-fork'],
 'context':['context-ready','context-detail','context-pending','context-error','context-scroll'],
 'extension page':['page-list','page-text','page-choice','page-confirm','page-empty','page-error','page-loading'],
}
SIZES=['120x40','80x24','40x10']
source=OUT/'baseline-ts-sources.json'
source_hash=hashlib.sha256(source.read_bytes()).hexdigest() if source.exists() else None
harness_hash=hashlib.sha256((ROOT/'cli/test/manual/visual_parity.py').read_bytes()).hexdigest()
renderer_hash=hashlib.sha256((ROOT/'cli/test/manual/visual_terminal.mjs').read_bytes()).hexdigest()
manifest=json.loads(source.read_text()) if source.exists() else {}
ts_source_matches=all(((ROOT/path).is_file() and hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest) or ('.test.' in path and not (ROOT/path).exists()) for path,digest in manifest.items())
def side(d,side):
 meta=d/f'{side}.actions.json'
 if not meta.exists():return None
 data=json.loads(meta.read_text())
 captures={p.stem[len(side)+1:]:str(p.relative_to(ATLAS)) for p in sorted(d.glob(f'{side}-*.png'))}
 valid=bool(captures) and data.get('sha256_harness')==harness_hash and data.get('sha256_renderer')==renderer_hash and all(data.get('assertions',{}).values())
 if side in ('ts','driver-ts'):
  valid=valid and data.get('sha256_ts_source_manifest')==source_hash and ts_source_matches
  if side=='driver-ts':valid=valid and data.get('sha256_fake_clipboard_driver')==hashlib.sha256((ROOT/'cli/test/manual/chat-clipboard.tsx').read_bytes()).hexdigest()
 elif side in ('before','after','final','driver'):
  binary=pathlib.Path(data.get('immutable_binary_path') or data.get('command',[''])[0])
  valid=valid and binary.is_file() and hashlib.sha256(binary.read_bytes()).hexdigest()==data.get('sha256_executable')
  if side in ('after','final'):valid=valid and final_sha256 is not None and data.get('sha256_executable')==final_sha256
 return {'screenshots':captures,'valid':valid,'assertions':data.get('assertions',{}),'scenario':data.get('scenario'),'fixture_variant':data.get('fixture_variant'),'size':data.get('size'),'terminated_by_harness':data.get('terminated_by_harness'),'go_source_manifest_sha256':data.get('sha256_go_sources'),'source_binary_path':data.get('source_binary_path'),'immutable_binary_path':data.get('immutable_binary_path'),'source_sha256':data.get('sha256_ts_source_manifest'),'binary_sha256':data.get('sha256_executable'),'harness_sha256':data.get('sha256_harness'),'actions':data.get('actions',[]),'snapshots':data.get('snapshots',{})}
rows={}
for group,names in STATES.items():
 for name in names:
  rows[name]={'group':group,'variants':{}}
  for size in SIZES:
   d=ATLAS/f'{name}-{size}'
   sides={side_name:side(d,side_name) for side_name in ('ts','before','after','final','driver-ts','driver')}
   pairs={}
   for other in ('before','after'):
    selected='final' if other=='after' and sides['final'] is not None else other
    a,b=sides['ts'],sides[selected]
    matched=bool(a and b and a['valid'] and b['valid'] and a['scenario']==b['scenario'] and a['fixture_variant']==b['fixture_variant'] and a['size']==b['size'] and a['actions']==b['actions'] and a['snapshots']==b['snapshots'])
    shared=sorted(set(a['screenshots'])&set(b['screenshots'])) if matched else []
    pairs[other]={'valid':bool(shared),'state_labels':shared,'binary_sha256':b['binary_sha256'] if b else None,'after_side':selected if other=='after' else None}
   rows[name]['variants'][size]={'sides':sides,'pairs':pairs}
# Also index worker-owned captures by actual directory and label, without pretending their screen is known.
known={f'{name}-{size}' for name in rows for size in SIZES}
extra={}
for d in sorted(ATLAS.iterdir()):
 if d.is_dir() and d.name not in known:
  sides={side_name:side(d,side_name) for side_name in ('ts','before','after','final','driver-ts','driver')}
  a=sides['ts'];chosen='final' if sides['final'] is not None else 'after';b=sides[chosen]
  matched=bool(a and b and a['valid'] and b['valid'] and all(a[key]==b[key] for key in ('scenario','fixture_variant','size','actions','snapshots')))
  fake,go=sides['driver-ts'],sides['driver']
  manual=bool(fake and go and fake['valid'] and go['valid'] and all(fake[key]==go[key] for key in ('scenario','fixture_variant','size')))
  extra[d.name]={'sides':sides,'paired_after_labels':sorted(set(a['screenshots'])&set(b['screenshots'])) if matched else [],'after_side':chosen,'manual_driver_pairs':{'valid':manual,'state_labels':sorted(set(fake['screenshots'])&set(go['screenshots'])) if manual else [],'note':'fake clipboard injection timings differ; manual driver is not shipped CLI' if manual else ''}}
coverage={'renderer':'real PTY ANSI -> @xterm/headless cells -> fixed-font PNG with 16/256/RGB, inverse, bold, dim, italic and CJK fallback','final_binary_path':str(final_binary),'final_binary_sha256':final_sha256,'ts_source_manifest_sha256':source_hash,'ts_source_matches_current_files':ts_source_matches,'harness_sha256':harness_hash,'renderer_sha256':renderer_hash,'font_note':'macOS SFNSMono/Hiragino; Linux DejaVuSansMono/Noto CJK where installed; override ALBEDO_VISUAL_FONT and ALBEDO_VISUAL_CJK_FONT','matrix':rows,'extra_capture_directories':extra}
(ATLAS/'coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
lines=['# real-pty visual parity atlas','','PNG screenshots are captures of live TS/Go CLI processes through the same PTY, xterm parser, font, theme, and dimensions. `coverage.json` marks stale fixture/renderer/source hashes invalid.','', '| state | size | ts | go-before | go-after | matched labels |','|---|---|---|---|---|---|']
for name,item in rows.items():
 for size,v in item['variants'].items():
  sides=v['sides']
  if not any(sides.values()):continue
  def link(side):
   data=sides['final'] if side=='after' and sides['final'] is not None else sides[side]
   if not data:return '—'
   screenshots=data['screenshots'];label=next(iter(screenshots),None)
   return f"[{'valid' if data['valid'] else 'stale'}]({screenshots[label]})" if label else '—'
  labels=', '.join(v['pairs']['before']['state_labels'] or v['pairs']['after']['state_labels']) or '—'
  lines.append(f'| {name} | {size} | {link("ts")} | {link("before")} | {link("after")} | {labels} |')
lines.extend(['', '## additional action-state captures', '', '| directory | ts | final go | matching labels |', '|---|---|---|---|'])
for name,item in extra.items():
 sides=item['sides'];chosen=item['after_side']
 def extra_link(side):
  data=sides.get(side)
  if not data:return '—'
  screenshot=next(iter(data['screenshots'].values()),None)
  return f"[{'valid' if data['valid'] else 'stale'}]({screenshot})" if screenshot else '—'
 labels=', '.join(item['paired_after_labels'] or item['manual_driver_pairs']['state_labels']) or '—'
 if not item['paired_after_labels'] and sides['driver-ts'] and sides[chosen]:
  labels=', '.join(sorted(set(sides['driver-ts']['screenshots']) & set(sides[chosen]['screenshots'])))+' (TS callback driver; Go CLI)'
 ts=extra_link('driver-ts') if item['manual_driver_pairs']['valid'] or sides['ts'] is None else extra_link('ts')
 go=extra_link('driver') if item['manual_driver_pairs']['valid'] else extra_link(chosen)
 lines.append(f'| {name} | {ts} | {go} | {labels} |')
(ATLAS/'INDEX.md').write_text('\n'.join(lines)+'\n')
print('states',len(rows),'extra',len(extra),'valid baseline pairs',sum(v['pairs']['before']['valid'] for row in rows.values() for v in row['variants'].values()),'valid after pairs',sum(v['pairs']['after']['valid'] for row in rows.values() for v in row['variants'].values()))
