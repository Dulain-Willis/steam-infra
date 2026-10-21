"""Generic scenario entrypoint, invoked by scripts/scenarios/run.sh once
the SSM tunnel to RDS is up. Connects with the same DB_HOST/PORT/NAME/
USER/PASSWORD env-var convention generator.py's connect() uses, then
calls the named scenario module's run(cur).

Deliberately not generator.connect() — scenario modules (and this loader)
must never import from generator.py, the generator's tick path (#131 AC).
"""

import importlib
import logging
import os
import sys

import psycopg2

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")


def connect():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
    )


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: _run.py <scenario_module>")
    module = importlib.import_module(sys.argv[1])

    conn = connect()
    conn.autocommit = True
    with conn.cursor() as cur:
        result = module.run(cur)
    logging.info("scenario %s result: %s", sys.argv[1], result)


if __name__ == "__main__":
    main()
