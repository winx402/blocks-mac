#!/usr/bin/env python3
"""Real temporary-filesystem transaction fixtures; no signing/build/launch."""
import importlib.util, os, plistlib, shutil, tempfile, sys, io, contextlib
from pathlib import Path
from unittest.mock import patch
R=Path(__file__).resolve().parents[2]; s=importlib.util.spec_from_file_location("dev",R/"script/development.py"); d=importlib.util.module_from_spec(s); s.loader.exec_module(d)

def test_pipeline_fixtures():
 sys.path.insert(0,str(R/"tools/verification"))
 import verification_build_helpers as h
 with tempfile.TemporaryDirectory() as directory:
  root=Path(directory).resolve();derived=root/"Derived.noindex";product=derived/"Tests/Build/Products/DebugTesting/Blocks.app";product.mkdir(parents=True)
  (derived/"Tests/Build/Products/fixture.xctestrun").write_text("fixture")
  installed=root/"Applications/Blocks Dev.app";installed.mkdir(parents=True)
  good={"ok":True,"returncode":0,"stdout":"fixture passed","stderr":"","timed_out":False}
  for scenario in ("success","build-cleanup-failure","test-failure","interrupt","registration-failure"):
   calls=[]
   def build(command,**kwargs):
    assert kwargs["retry_cleaned_ibtoold"] is True
    calls.append("build")
    if scenario=="interrupt":raise KeyboardInterrupt()
    if scenario=="build-cleanup-failure":return {**good,"ok":False,"child_returncode":0,"process_cleanup":{"status":"target_group_residual_cleaned"}}
    return good
   def test(command,**kwargs):
    calls.append("test");return {**good,"ok":scenario!="test-failure"}
   def unregister(command,**kwargs):
    assert command==[h._LSREGISTER,"-u",str(product)];calls.append("unregister")
    if scenario=="registration-failure":raise OSError("fixture unregister failed")
   output=io.StringIO()
   with patch.object(d,"doctor",lambda:None),patch.object(d,"DERIVED",derived),patch.object(h,"run_controlled_xcode_build",build),patch.object(h,"run_controlled_xcode_test",test),patch.object(h.subprocess,"run",unregister),contextlib.redirect_stdout(output),contextlib.redirect_stderr(io.StringIO()):
    try:d.test()
    except KeyboardInterrupt:assert scenario=="interrupt"
    except RuntimeError as error:
     assert scenario in ("build-cleanup-failure","test-failure","registration-failure")
     if scenario=="build-cleanup-failure":assert "xcodebuild succeeded (exit 0)" in str(error)
    else:assert scenario=="success"
   assert calls[-1]=="unregister" and ("test" in calls)==(scenario in ("success","test-failure","registration-failure")),calls
   assert ("PASS: isolated XCTest completed" in output.getvalue())==(scenario=="success")
   assert product.is_dir() and installed.is_dir()
def app(p,m):
 for x in ("Contents/MacOS/Blocks Dev","Contents/MacOS/BlocksActionBroker","Contents/Resources/CLI/blocks","Contents/Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper"):
  q=p/x;q.parent.mkdir(parents=True,exist_ok=True);q.write_text(m);q.chmod(0o755)
 (p/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"app.blocks.dev"})); h=p/"Contents/Helpers/Blocks Selection Helper.app/Contents/Info.plist";h.write_bytes(plistlib.dumps({"CFBundleURLTypes":[]})); a=p/"Contents/Library/LaunchAgents/app.blocks.action-broker.plist";a.parent.mkdir(parents=True,exist_ok=True);a.write_bytes(plistlib.dumps({}))
def main():
 test_pipeline_fixtures()
 with tempfile.TemporaryDirectory() as t:
  root=Path(t); prod=root/"p";app(prod/"Blocks Dev.app","new");shutil.rmtree(prod/"Blocks Dev.app/Contents/Helpers");app(prod/"Blocks Selection Helper.app","h");(prod/"blocks").write_text("c")
  old={k:getattr(d,k) for k in ("HOME","DESTINATION","MANIFEST","run","sign","signature","rename_display","update_plist","running_local_processes")};d.HOME=root;d.DESTINATION=root/"Apps/Blocks Dev.app";d.MANIFEST=root/"Support/peers.json";d.ensure_real_directory=lambda p:p.mkdir(parents=True,exist_ok=True);d.running_local_processes=lambda:[];d.sign=lambda *_:None;d.rename_display=lambda *_:None;d.update_plist=lambda p,f:(lambda x:(f(x),p.write_bytes(plistlib.dumps(x))))(plistlib.loads(p.read_bytes()))
  def run(c,**_):
   if c[0]=="/usr/bin/ditto":shutil.copytree(c[1],c[2],symlinks=True)
   return ""
  d.run=run
  def sig(p):
   n=str(p);return {"Identifier":"app.blocks.dev.selection-helper" if "Helper" in n else "app.blocks.dev.cli" if p.name=="blocks" else "app.blocks.dev.action-broker" if p.name=="BlocksActionBroker" else "app.blocks.dev","CDHash":"a"*40}
  d.signature=sig
  try:
   u=os.umask(0o022);d.install_development(prod);os.umask(u);assert (d.MANIFEST.stat().st_mode&0o777)==0o600
   app(d.DESTINATION,"old");d.MANIFEST.write_text("old");
   real=os.replace; hit=[0]
   def bad(s,t):
    if Path(t)==d.MANIFEST and not hit[0]:hit[0]=1;raise OSError("manifest")
    return real(s,t)
   d.os.replace=bad
   try:
    try:d.install_development(prod)
    except (RuntimeError,OSError):pass
    else:raise AssertionError("manifest")
   finally:d.os.replace=real
   assert (d.DESTINATION/"Contents/MacOS/Blocks Dev").read_text()=="old" and d.MANIFEST.read_text()=="old"
   # Interrupt before/after the atomic manifest write, with and without an old install.
   saved_destination,saved_manifest=d.DESTINATION,d.MANIFEST
   try:
    for existing in (False,True):
     for after_write in (False,True):
      case=root/f"interrupt-{existing}-{after_write}"
      d.DESTINATION=case/"Apps/Blocks Dev.app";d.MANIFEST=case/"Support/peers.json"
      if existing:
       app(d.DESTINATION,"previous");d.MANIFEST.parent.mkdir(parents=True);d.MANIFEST.write_text("previous");d.MANIFEST.chmod(0o600)
      interrupted=[False]
      def interrupt_manifest(source,target):
       if Path(target)==d.MANIFEST and not interrupted[0]:
        interrupted[0]=True
        if after_write:real(source,target)
        raise KeyboardInterrupt()
       return real(source,target)
      d.os.replace=interrupt_manifest
      try:
       try:d.install_development(prod)
       except KeyboardInterrupt:pass
       else:raise AssertionError("interruption-not-observed")
      finally:d.os.replace=real
      assert interrupted[0]
      if existing:
       assert (d.DESTINATION/"Contents/MacOS/Blocks Dev").read_text()=="previous" and d.MANIFEST.read_text()=="previous"
      else:
       assert not d.DESTINATION.exists() and not d.MANIFEST.exists()
   finally:d.DESTINATION,d.MANIFEST=saved_destination,saved_manifest
   # Reader-compatible identity validation rejects malformed peers before host mutation.
   for bad in ("app.blocks.dev", "a"*41):
    saved=d.signature
    d.signature=(lambda p,bad=bad: {"Identifier":bad if p.name=="blocks" else saved(p)["Identifier"],"CDHash":"a"*40 if bad!="a"*41 else bad})
    try:
     try:d.install_development(prod)
     except RuntimeError:pass
     else:raise AssertionError("bad-peer")
    finally:d.signature=saved
    assert (d.DESTINATION/"Contents/MacOS/Blocks Dev").read_text()=="old"
   # A non-private prior manifest is rejected without replacing either peer.
   d.MANIFEST.chmod(0o644)
   try:
    try:d.install_development(prod)
    except RuntimeError:pass
    else:raise AssertionError("public-manifest")
   finally:d.MANIFEST.chmod(0o600)
   assert d.MANIFEST.read_text()=="old"
   # Create an empty concurrent target immediately before real RENAME_EXCL.
   real_promote=d.promote_without_replacing; raced=[False]
   def race(source,target):
    if not raced[0] and Path(target)==d.DESTINATION:
     raced[0]=True;Path(target).mkdir()
    return real_promote(source,target)
   d.promote_without_replacing=race
   try:
    try:d.install_development(prod)
    except OSError:pass
    else:raise AssertionError("race")
   finally:d.promote_without_replacing=real_promote
   assert d.DESTINATION.is_dir() and list((root/"Library/Caches/BlocksDev/DevelopmentInstall.noindex").glob("*/previous.app"))
   lock=d.DESTINATION.parent/".BlocksDev-install.lock";lock.mkdir()
   try:
    try:d.install_development(prod)
    except RuntimeError:pass
    else:raise AssertionError("lock")
   finally:lock.rmdir()
  finally:
   for k,v in old.items():setattr(d,k,v)
 print('{"ok":true,"cases":["first","upgrade-manifest-failure","lock","manifest-0600","cli-identifier-rejected","hash-rejected","public-manifest-rejected","concurrent-empty-target-preserved","first-interrupt-before-manifest","first-interrupt-after-manifest","upgrade-interrupt-before-manifest","upgrade-interrupt-after-manifest"]}')
if __name__=="__main__":main()
