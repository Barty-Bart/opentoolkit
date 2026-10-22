"""Shared local library. Legacy files are read once and never removed or rewritten."""
import json,sqlite3,os
from pathlib import Path

def library_path():
    return Path.home()/'Library/Application Support/Pico/library.sqlite'

def connect(path=None,legacy=None):
    path=Path(path) if path else library_path()
    path.parent.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(path,timeout=5,check_same_thread=False)
    os.chmod(path,0o600)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript(Path(__file__).with_name('library_schema.sql').read_text())
    if legacy is not None:migrate_history(db,Path(legacy))
    return db

def migrate_history(db,path):
    key='migration:dictations'
    if not path.exists():return
    with db:
        db.execute('BEGIN IMMEDIATE')
        if db.execute('SELECT 1 FROM library_meta WHERE key=?',(key,)).fetchone():return
        source=sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True)
        try:rows=source.execute('SELECT id,created_at,text,app,audio_seconds,transcribe_ms,model FROM dictations').fetchall()
        finally:source.close()
        db.executemany('INSERT INTO dictations(id,created_at,text,app,audio_seconds,transcribe_ms,model) VALUES(?,?,?,?,?,?,?)',rows)
        db.execute('INSERT INTO library_meta VALUES(?,?)',(key,'1'))

def get_value(key,legacy=None,default='',path=None):
    with connect(path) as db:
        db.execute('BEGIN IMMEDIATE')
        row=db.execute('SELECT value FROM library_meta WHERE key=?',(key,)).fetchone()
        if row:return row[0]
        value=Path(legacy).read_text() if legacy and Path(legacy).exists() else default
        if key=='corrections':
            data=json.loads(value)
            if not isinstance(data,list):raise ValueError('Invalid legacy correction rules')
        db.execute('INSERT INTO library_meta VALUES(?,?)',(key,value))
        return value

def set_value(key,value,path=None):
    with connect(path) as db:
        db.execute('INSERT INTO library_meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',(key,value))
