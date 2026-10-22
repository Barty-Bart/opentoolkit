import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from indicator_layout import place_indicator,glow_frame

class IndicatorLayoutTests(unittest.TestCase):
    def test_tracks_caret_instead_of_mouse_screen(self):
        frames=[(0,0,1440,875),(-1920,0,1920,1055)]
        x,y=place_indicator(frames,(200,300),(-1200,400,1,20),(58,22))
        self.assertEqual((x,y),(-1192,372))
    def test_flips_above_caret_at_bottom(self):
        self.assertEqual(place_indicator([(0,30,1000,700)],(0,0),(200,35,1,20),(58,22)),(208,61))
    def test_right_edge_remains_visible(self):
        x,y=place_indicator([(0,0,1000,700)],(0,0),(998,680,1,20),(58,22))
        self.assertEqual(x,934)
        self.assertGreaterEqual(y,8)
        self.assertLessEqual(y+22,692)
    def test_display_above_primary(self):
        x,y=place_indicator([(0,0,1000,700),(0,700,1000,700)],(20,20),(400,900,1,20),(32,32))
        self.assertEqual((x,y),(408,862))
    def test_missing_caret_uses_mouse_display(self):
        self.assertEqual(place_indicator([(0,0,1000,700),(-1000,0,1000,700)],(-400,300),None,(22,22)),(-511,40))
    def test_offscreen_caret_clamps_to_nearest_screen(self):
        x,y=place_indicator([(0,0,1000,700)],(20,20),(-100,800,1,20),(58,22))
        self.assertEqual((x,y),(8,670))
class GlowLayoutTests(unittest.TestCase):
    def test_padding_keeps_stroke_inside_panel(self):
        self.assertEqual(glow_frame((100,100,500,100),[(0,0,1000,700)],(120,120,1,20)),(92,92,516,116))
    def test_reject_wrong_field(self):
        self.assertIsNone(glow_frame((100,100,500,100),[(0,0,1000,700)],(700,400,1,20)))
    def test_reject_window_sized_bounds(self):
        self.assertIsNone(glow_frame((0,0,1000,700),[(0,0,1000,700)]))
    def test_clip_to_screen(self):
        self.assertEqual(glow_frame((-10,10,500,100),[(0,0,1000,700)]),(0,2,498,116))
    def test_reject_invalid_geometry(self):
        self.assertIsNone(glow_frame((float('nan'),0,100,100),[(0,0,1000,700)]))


class FieldFallbackTests(unittest.TestCase):
    def test_stays_beside_input_when_caret_missing(self):
        from indicator_layout import place_near_field
        self.assertEqual(place_near_field([(0,0,1440,900)],(100,300,800,100),(34,22)),(108,272))
    def test_rejects_window_as_input(self):
        from indicator_layout import place_near_field
        self.assertIsNone(place_near_field([(0,0,1440,900)],(0,0,1440,900),(34,22)))
    def test_low_input_flips_above(self):
        from indicator_layout import place_near_field
        self.assertEqual(place_near_field([(0,0,1440,900)],(100,10,800,100),(34,22)),(108,116))

if __name__=='__main__':unittest.main()
