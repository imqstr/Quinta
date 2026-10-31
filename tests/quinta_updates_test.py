import urllib.error
import unittest
from unittest.mock import patch

from quinta import core


class QuintaUpdateTests(unittest.TestCase):
    def test_new_fork_without_releases_is_not_a_network_failure(self):
        error = urllib.error.HTTPError(core.LAUNCHER_RELEASE_URL, 404, 'Not Found', {}, None)
        with patch.object(core.urllib.request, 'urlopen', side_effect=error):
            self.assertEqual(core.check_launcher_update(), (False, '', core.RELEASES_URL))

    def test_rate_limit_is_not_reported_as_no_updates(self):
        error = urllib.error.HTTPError(core.LAUNCHER_RELEASE_URL, 403, 'Forbidden', {}, None)
        with patch.object(core.urllib.request, 'urlopen', side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                core.check_launcher_update()
