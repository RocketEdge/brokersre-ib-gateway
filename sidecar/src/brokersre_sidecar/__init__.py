"""brokersre-ib-gateway-sidecar: probe, status API, metrics and notifier for the IB Gateway image.

The package observes one IB Gateway container (shared network namespace, read-only log volume)
and never acts on it: it places no orders, sends nothing to the IBC command server and restarts
nothing. Layers, lowest first (enforced by ``tests/test_architecture.py``):

``config`` and the leaf utilities, then ``tail`` and ``model``, then ``probe``, ``notify``,
``http``, ``metrics`` and ``support``, then ``app`` (the only wiring place), then ``cli``.
"""

__version__ = "0.1.0"

__all__ = ["__version__"]
