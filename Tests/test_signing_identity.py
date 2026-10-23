import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import signing_identity as signing


class SigningIdentityTests(unittest.TestCase):
    def component(self, identifier='local.pico', team='SAMPLE', requirement='stable', developer=True):
        return dict(identifier=identifier, team=team, requirement=requirement, developer_id=developer)

    def test_same_identity_update_allowed_for_both_components(self):
        app=self.component(); helper=self.component('local.pico.speech')
        with patch.object(Path, 'exists', return_value=True), patch.object(signing, 'identity', side_effect=[app, app, helper, helper]), patch.object(signing.subprocess, 'run') as run:
            signing.validate_upgrade(Path('installed'), Path('new'))
            run.assert_called_once()

    def test_ad_hoc_wrong_team_or_requirement_cannot_replace_signed_release(self):
        for changed in [self.component(team='not set'), self.component(team='OTHER'), self.component(requirement='changed'), self.component(identifier='new.bundle')]:
            with self.subTest(changed=changed), patch.object(Path, 'exists', return_value=True), patch.object(signing, 'identity', side_effect=[self.component(), changed]), patch.object(signing.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'changes the installed signing identity'):
                    signing.validate_upgrade(Path('installed'), Path('new'))
                run.assert_not_called()

    def test_release_requires_matching_team_and_helper_id(self):
        for helper in [self.component('wrong.helper'), self.component('local.pico.speech', team='OTHER'), self.component('local.pico.speech', developer=False)]:
            with patch.object(signing, 'identity', side_effect=[self.component(), helper]), patch.object(signing.subprocess, 'run'):
                with self.assertRaises(ValueError): signing.validate_release(Path('app'))

    def test_requirement_can_be_on_stdout(self):
        output=Mock(returncode=0, stdout='designated => anchor apple generic\n', stderr='Identifier=local.pico\nTeamIdentifier=SAMPLE\nAuthority=Developer ID Application: Sample\n')
        with patch.object(signing.subprocess, 'run', return_value=output):
            self.assertEqual(signing.identity(Path('app'))['requirement'], 'anchor apple generic')


if __name__ == '__main__': unittest.main()
