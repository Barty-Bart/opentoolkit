import hashlib,importlib.util,io,json,tarfile,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch,Mock
spec=importlib.util.spec_from_file_location('installer',Path(__file__).resolve().parents[1]/'scripts/install.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
class InstallerTests(unittest.TestCase):
    def test_supported_platform(self):installer.check_system('Darwin','arm64','14.0',(3,12))
    def test_unsupported_platforms(self):
        for args in [('Linux','arm64','14.0',(3,12)),('Darwin','x86_64','14.0',(3,12)),('Darwin','arm64','13.6',(3,12)),('Darwin','arm64','26.0',(3,11))]:
            with self.assertRaises(ValueError):installer.check_system(*args)
    def archive(self,root,bad=None):
        path=root/'model.tar.bz2'
        with tarfile.open(path,'w:bz2') as tar:
            for i,name in enumerate(sorted(installer.MODEL_FILES)):
                info=tarfile.TarInfo(installer.MODEL+'/'+name);info.size=4
                if i==0 and bad=='symlink':info.type=tarfile.SYMTYPE;info.linkname='../../outside'
                tar.addfile(info,io.BytesIO(b'test'))
            info=tarfile.TarInfo('../../outside');info.size=4;tar.addfile(info,io.BytesIO(b'evil'))
        return path,hashlib.sha256(path.read_bytes()).hexdigest()
    def test_checksum_precedes_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);archive,_=self.archive(root)
            with self.assertRaises(ValueError):installer.extract_wake_model(archive,root/'out','wrong')
            self.assertFalse((root/'out').exists())
    def test_whitelist_only_no_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);archive,digest=self.archive(root);installer.extract_wake_model(archive,root/'out',digest)
            self.assertEqual({p.name for p in (root/'out').iterdir()},installer.MODEL_FILES)
    def test_symlink_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);archive,digest=self.archive(root,'symlink')
            with self.assertRaises(ValueError):installer.extract_wake_model(archive,root/'out',digest)
            self.assertEqual(list((root/'out').iterdir()),[])
    def test_live_speech_blocks_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'VoiceBridge').mkdir();(root/'VoiceBridge/state.json').write_text(json.dumps({'time':time.time(),'recording':True}))
            with self.assertRaises(ValueError):installer.assert_idle(root,root/'Pico.app')
    def test_loading_worker_blocks_install(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(installer.subprocess,'run',return_value=Mock(returncode=0,stdout='')):
            with self.assertRaises(ValueError):installer.assert_idle(Path(tmp),Path(tmp)/'Pico.app')
    def test_install_preserves_library_and_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'built';source.mkdir();(source/'binary').write_text('new')
            app=root/'Applications/Pico.app';app.mkdir(parents=True);(app/'binary').write_text('old')
            runtime=root/'Data/Speech';runtime.mkdir(parents=True);(runtime/'dictate.py').write_text('old worker')
            database=root/'Data/library.sqlite';database.write_bytes(b'private-data')
            backup=installer.install_files(source,app,runtime)
            self.assertEqual(database.read_bytes(),b'private-data');self.assertEqual((backup/'Pico.app/binary').read_text(),'old')
            self.assertEqual((backup/'dictate.py').read_text(),'old worker');self.assertEqual((app/'binary').read_text(),'new')
if __name__=='__main__':unittest.main()
