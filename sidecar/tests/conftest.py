"""Suite-wide configuration: property-based tests are deterministic and write nothing.

* ``derandomize``: Hypothesis derives its examples from the test itself, so every run on
  every machine explores the same cases (a failure in CI reproduces locally).
* ``database=None``: no example database is written; the suite also passes when the
  working directory is read-only.
* ``deadline=None``: a slow or busy machine cannot turn a correct test into a failure.
"""

from hypothesis import settings

settings.register_profile("sidecar", database=None, deadline=None, derandomize=True)
settings.load_profile("sidecar")
