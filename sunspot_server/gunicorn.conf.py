import os


def post_fork(server, worker):
    """Reinitialize Sentry in each worker after fork.

    Required because --preload forks workers from the master process and
    Sentry's transport thread does not survive the fork.
    """
    dsn = os.getenv('SENTRY_DSN', '')
    if not dsn:
        return
    try:
        import sentry_sdk
        from sentry_sdk.integrations.flask import FlaskIntegration
        sentry_sdk.init(
            dsn=dsn,
            integrations=[FlaskIntegration()],
            traces_sample_rate=1.0,
            environment=os.getenv('FLASK_ENV', 'production'),
        )
        print(f"[sentry] worker {worker.pid} initialized", flush=True)
    except Exception as e:
        print(f"[sentry] post_fork init failed: {e}", flush=True)
