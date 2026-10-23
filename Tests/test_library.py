import unittest,tempfile,sqlite3,json,sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from library_store import connect,migrate_history,get_value,set_value
from text_formatting import format_text

class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.path=self.root/'library.sqlite';self.db=connect(self.path)
    def tearDown(self):self.db.close();self.temp.cleanup()
    def add(self,text='Unique dragonfruit',id=1):
        self.db.execute('INSERT INTO dictations(id,text,original_text,writing_mode) VALUES(?,?,?,?)',(id,text,'Original','email'));self.db.commit()
    def search(self,q):return self.db.execute('SELECT text FROM chunk_search WHERE chunk_search MATCH ?',(q,)).fetchall()
    def test_create_history_indexes_and_keeps_original(self):
        self.add();self.assertTrue(self.search('dragonfruit'));self.assertEqual(self.db.execute('SELECT original_text,writing_mode FROM dictations').fetchone(),('Original','email'))
    def test_edit_updates_search(self):
        self.add()
        self.db.execute('UPDATE dictations SET text=?',('Apricot',));self.db.commit()
        self.assertFalse(self.search('dragonfruit'));self.assertTrue(self.search('Apricot'))
    def test_delete_removes_all_search(self):
        self.add()
        self.db.execute('DELETE FROM dictations');self.db.commit()
        for table in ('items','chunks'):self.assertEqual(self.db.execute('SELECT count(*) FROM '+table).fetchone()[0],0)
        self.assertFalse(self.search('dragonfruit'))
    def legacy(self):
        p=self.root/'old.sqlite'
        with sqlite3.connect(p) as db:
            db.execute('CREATE TABLE dictations(id INTEGER PRIMARY KEY,created_at TEXT,text TEXT,app TEXT,audio_seconds REAL,transcribe_ms INTEGER,model TEXT)')
            db.execute("INSERT INTO dictations VALUES(7,'2026-10-22 11:00:00','Legacy phrase','Test',2,10,'synthetic')")
        return p
    def test_migration_idempotent_and_source_unchanged(self):
        old=self.legacy();data=old.read_bytes();migrate_history(self.db,old);migrate_history(self.db,old)
        self.assertEqual(self.db.execute('SELECT count(*) FROM dictations').fetchone()[0],1);self.assertTrue(self.search('Legacy'));self.assertEqual(old.read_bytes(),data)
    def test_failed_migration_rolls_back_and_not_marked(self):
        old=self.legacy();self.add(id=7)
        with self.assertRaises(sqlite3.IntegrityError):migrate_history(self.db,old)
        self.assertFalse(self.db.execute("SELECT 1 FROM library_meta WHERE key='migration:dictations'").fetchone());self.assertEqual(self.db.execute('SELECT text FROM dictations').fetchone()[0],'Unique dragonfruit')
    def test_bad_corrections_preserved_and_not_migrated(self):
        p=self.root/'corrections.json';p.write_text('broken')
        with self.assertRaises(ValueError):get_value('corrections',p,'[]',self.path)
        self.assertEqual(p.read_text(),'broken');self.assertIsNone(self.db.execute("SELECT value FROM library_meta WHERE key='corrections'").fetchone())
    def test_settings_move_once(self):
        p=self.root/'rules.txt';p.write_text('old => new')
        self.assertEqual(get_value('manual_replacements',p,'',self.path),'old => new');set_value('manual_replacements','different => rule',self.path)
        self.assertEqual(get_value('manual_replacements',p,'',self.path),'different => rule');self.assertEqual(p.read_text(),'old => new')
    def test_concurrent_writers(self):
        def write(n):
            db=connect(self.path)
            with db:db.execute('INSERT INTO dictations(text) VALUES(?)',(f'Concurrent {n}',))
            db.close()
        with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(write,range(20)))
        self.assertEqual(self.db.execute('SELECT count(*) FROM dictations').fetchone()[0],20)
        self.assertEqual(len(self.search('Concurrent')),20)
    def test_usage_log_schema_is_additive(self):
        self.add();again=connect(self.path);again.close()
        cols=[r[1] for r in self.db.execute('PRAGMA table_info(usage_events)')]
        self.assertEqual(cols,['id','at','kind','trigger','seconds'])
        self.assertEqual(self.db.execute("SELECT value FROM library_meta WHERE key='schema_version'").fetchone()[0],'2')
        self.add('Second dictation',id=2);self.assertEqual(self.db.execute('SELECT count(*) FROM dictations').fetchone()[0],2)
    def test_private_db(self):self.assertEqual(self.path.stat().st_mode&0o777,0o600)
    def test_unicode_and_quote(self):
        self.add('Zażółć gęślą jaźń. O\'Brien 🐙');self.assertTrue(self.search('"Zażółć"'));self.assertTrue(self.search('"Brien"'))
    def test_fk_folder_delete_preserves_note(self):
        self.add();self.db.execute("INSERT INTO folders VALUES('f','Test')");self.db.execute("UPDATE items SET folder='f'");self.db.execute("DELETE FROM folders");self.assertIsNone(self.db.execute('SELECT folder FROM items').fetchone()[0]);self.assertTrue(self.search('dragonfruit'))

class WritingModesTests(unittest.TestCase):
    def test_email(self):self.assertEqual(format_text('Hi Sam, The report is ready. Cheers, Alex',False,'email'),'Hi Sam,\n\nThe report is ready.\n\nCheers,\nAlex')
    def test_messages_are_paragraphs_not_sends(self):self.assertEqual(format_text('First. Second. Third.',False,'message',2),'First. Second.\n\nThird.')
    def test_bullets_keep_all_sentences(self):self.assertEqual(format_text('One. Two?',False,'bullets'),'• One.\n• Two?')
    def test_verbatim_spaces(self):self.assertEqual(format_text('Keep  this',False,'verbatim'),'Keep  this')
    def test_clean_does_not_rewrite(self):self.assertEqual(format_text('Well,  um, yes.',False,'clean'),'Well, um, yes.')
    def test_unknown_mode_preserves_text(self):self.assertEqual(format_text('First. Second.',False,'unexpected'),'First. Second.')
    def test_invalid_message_size_safe(self):self.assertEqual(format_text('One. Two. Three.',False,'message',None),'One. Two.\n\nThree.')

if __name__=='__main__':unittest.main()
