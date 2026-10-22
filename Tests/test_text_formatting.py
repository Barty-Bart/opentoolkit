import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from text_formatting import format_text
class FormattingTests(unittest.TestCase):
    def test_off_preserves_words(self):self.assertEqual(format_text('new paragraph'),'new paragraph')
    def test_linebreaks(self):self.assertEqual(format_text('First. New paragraph. Second new line third',True),'First.\n\nSecond\nthird')
    def test_email(self):self.assertEqual(format_text("I'm writing an email. Hi Taylor, How are you? Cheers, Alex",True),'Hi Taylor,\n\nHow are you?\n\nCheers,\nAlex')
    def test_mid_sentence_preserved(self):self.assertEqual(format_text("Yesterday I said I'm writing an email.",True),"Yesterday I said I'm writing an email.")
if __name__=='__main__':unittest.main()
